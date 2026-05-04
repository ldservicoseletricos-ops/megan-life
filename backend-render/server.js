require('dotenv').config();

const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const multer = require('multer');
const JSZip = require('jszip');
const mammoth = require('mammoth');
const pdfParse = require('pdf-parse');
const { createWorker } = require('tesseract.js');
const { PDFDocument, StandardFonts } = require('pdf-lib');
const xlsx = require('xlsx');
const { Document, Packer, Paragraph, TextRun } = require('docx');
const { GoogleGenAI } = require('@google/genai');
const { createClient } = require('@supabase/supabase-js');
const textToSpeech = require('@google-cloud/text-to-speech');

const app = express();
const port = Number(process.env.PORT || 10000);
const model = process.env.GEMINI_MODEL || 'gemini-2.5-flash';
const ai = process.env.GEMINI_API_KEY ? new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY }) : null;

// Controle leve para evitar processamento duplicado no /api/chat sem afetar os outros módulos.
const chatRequestLocks = new Map();
const recentChatMessages = new Map();
const recentChatAnswers = new Map();
const CHAT_DUPLICATE_WINDOW_MS = Number(process.env.CHAT_DUPLICATE_WINDOW_MS || 3500);
const CHAT_LOCK_TTL_MS = Number(process.env.CHAT_LOCK_TTL_MS || 45000);
const CHAT_MEMORY_LIMIT = Number(process.env.CHAT_MEMORY_LIMIT || 80);
const CHAT_RECENT_LIMIT = Number(process.env.CHAT_RECENT_LIMIT || 12);

let ttsClient = null;

try {
  if (process.env.GOOGLE_CLOUD_TTS_CREDENTIALS_JSON) {
    const credentials = JSON.parse(process.env.GOOGLE_CLOUD_TTS_CREDENTIALS_JSON);
    ttsClient = new textToSpeech.TextToSpeechClient({ credentials });
  } else {
    ttsClient = new textToSpeech.TextToSpeechClient();
  }
} catch (e) {
  console.error('Erro ao iniciar Google Cloud TTS:', e.message);
}

const supabaseUrl = process.env.SUPABASE_URL || '';
const supabaseServiceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY || '';
const supabase = supabaseUrl && supabaseServiceKey ? createClient(supabaseUrl, supabaseServiceKey) : null;

const dataDir = path.join(__dirname, 'data');
const memoryFile = path.join(dataDir, 'memory.json');
const feedbackFile = path.join(dataDir, 'feedback.json');
const generatedDir = path.join(__dirname, 'generated');

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: Number(process.env.MAX_UPLOAD_MB || 50) * 1024 * 1024 }
});

app.disable('x-powered-by');
app.use(cors({ origin: true }));
app.use(express.json({ limit: '10mb' }));
app.use('/downloads', express.static(generatedDir));

function ensureDataDir() {
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
  if (!fs.existsSync(generatedDir)) fs.mkdirSync(generatedDir, { recursive: true });
}

function readJson(file, fallback) {
  try {
    ensureDataDir();
    if (!fs.existsSync(file)) return fallback;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return fallback;
  }
}

function writeJson(file, data) {
  ensureDataDir();
  fs.writeFileSync(file, JSON.stringify(data, null, 2), 'utf8');
}

function sanitizeText(value, max = 12000) {
  return String(value || '').replace(/\u0000/g, '').trim().slice(0, max);
}

function normalizeForDuplicateCheck(value) {
  return sanitizeText(value, 12000)
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function cleanupExpiredChatState() {
  const now = Date.now();

  for (const [key, item] of chatRequestLocks.entries()) {
    if (!item?.createdAt || now - item.createdAt > CHAT_LOCK_TTL_MS) {
      chatRequestLocks.delete(key);
    }
  }

  for (const [key, item] of recentChatMessages.entries()) {
    if (!item?.at || now - item.at > CHAT_DUPLICATE_WINDOW_MS) {
      recentChatMessages.delete(key);
    }
  }
}

function dedupeRepeatedLines(value) {
  const text = cleanMeganOutput(value, 90000);
  if (!text) return '';

  const lines = text.split('\n');
  const result = [];
  let previousNormalized = '';

  for (const line of lines) {
    const normalized = line.toLowerCase().replace(/\s+/g, ' ').trim();

    if (normalized && normalized === previousNormalized) {
      continue;
    }

    result.push(line);
    if (normalized) previousNormalized = normalized;
  }

  return result.join('\n').replace(/\n{4,}/g, '\n\n').trim();
}


function cleanMeganOutput(value, max = 90000) {
  let text = sanitizeText(value, max);

  if (!text) return '';

  return text
    .replace(/\\n/g, '\n')
    .replace(/\r/g, '')
    .replace(/\$1/g, '')
    .replace(/\$\{?1\}?/g, '')
    .replace(/\[\$1\]/g, '')
    .replace(/\*\s*\$1\s*/g, '* ')
    .replace(/\$1\s*/g, '')
    .replace(/\*\s{2,}/g, '* ')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n[ \t]+/g, '\n')
    .replace(/\n{4,}/g, '\n\n')
    .replace(/[ \t]{2,}/g, ' ')
    .trim();
}

function formatTextChatGPTStyle(value, max = 90000) {
  const text = cleanMeganOutput(value, max);
  if (!text) return '';

  const lines = text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);

  if (!lines.length) return text;

  const result = [];
  let currentSection = '';

  const pushSection = (section) => {
    if (currentSection === section) return;
    currentSection = section;
    if (result.length) result.push('');
    result.push(section);
  };

  for (let rawLine of lines) {
    let line = rawLine
      .replace(/^[-*•]\s*/, '')
      .replace(/^#+\s*/, '')
      .replace(/\s+/g, ' ')
      .trim();

    if (!line) continue;

    const lower = line.toLowerCase();

    if (lower.includes('orçamento') || lower.includes('orcamento') || lower.includes('crédito') || lower.includes('credito')) {
      pushSection('📄 Resumo do documento');
      result.push(`• ${line}`);
      continue;
    }

    if (lower.includes('cpf') || lower.includes('cnpj') || lower.includes('endereço') || lower.includes('endereco') || lower.includes('cliente') || lower.includes('consumidor')) {
      pushSection('👤 Dados identificados');
      result.push(`• ${line}`);
      continue;
    }

    if (lower.includes('volkswagen') || lower.includes('vw') || lower.includes('polo') || lower.includes('veículo') || lower.includes('veiculo') || lower.includes('flex') || lower.includes('tsi') || lower.includes('automóvel') || lower.includes('automovel')) {
      pushSection('🚗 Veículo');
      result.push(`• ${line}`);
      continue;
    }

    if (lower.includes('valor') || lower.includes('total') || lower.includes('parcela') || lower.includes('entrada') || lower.includes('r$')) {
      pushSection('💰 Valores');
      result.push(`• ${line}`);
      continue;
    }

    if (line.length <= 90 && /:$/.test(line)) {
      if (result.length) result.push('');
      result.push(line);
      currentSection = line;
      continue;
    }

    if (/^\d+[.)]\s+/.test(line)) {
      result.push(line);
      continue;
    }

    if (/^[-*•]/.test(rawLine.trim())) {
      result.push(`• ${line}`);
      continue;
    }

    result.push(line);
  }

  return result
    .join('\n')
    .replace(/\n{4,}/g, '\n\n')
    .replace(/\n\s*•\s*\n/g, '\n')
    .trim();
}

function cleanFactValue(value) {
  return sanitizeText(value, 300)
    .replace(/[.。!！?？]+$/g, '')
    .replace(/^['"“”‘’]+|['"“”‘’]+$/g, '')
    .trim();
}

function escapeSsml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function buildHumanSsml(text) {
  const clean = sanitizeText(text, 4500)
    .replace(/\s+/g, ' ')
    .trim();

  const escaped = escapeSsml(clean)
    .replace(/([.!?])\s+/g, '$1<break time="280ms"/> ')
    .replace(/,\s+/g, ',<break time="120ms"/> ');

  return `<speak><prosody rate="96%" pitch="+0st">${escaped}</prosody></speak>`;
}

async function getUserMemory(userId, limit = 120) {
  if (supabase) {
    const { data, error } = await supabase
      .from('megan_memories')
      .select('role, content, metadata, created_at')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(limit);

    if (!error && Array.isArray(data)) {
      return data.reverse().map((item) => ({
        role: item.role,
        content: item.content,
        metadata: item.metadata || {},
        at: item.created_at
      }));
    }

    console.error('Erro ao buscar memória no Supabase:', error?.message || error);
  }

  const all = readJson(memoryFile, {});
  return Array.isArray(all[userId]) ? all[userId].slice(-limit) : [];
}

async function addMemoryItem(userId, role, content, metadata = {}) {
  const cleanContent = sanitizeText(content, 90000);
  if (!cleanContent) return null;

  const item = {
    role,
    content: cleanContent,
    metadata: {
      ...metadata,
      appVersion: '4.2.3',
    },
    at: new Date().toISOString()
  };

  if (supabase) {
    const { error } = await supabase.from('megan_memories').insert({
      user_id: userId,
      role,
      content: cleanContent,
      metadata: item.metadata
    });

    if (!error) return item;
    console.error('Erro ao salvar memória no Supabase:', error.message);
  }

  const all = readJson(memoryFile, {});
  const list = Array.isArray(all[userId]) ? all[userId] : [];
  list.push(item);
  all[userId] = list.slice(-300);
  writeJson(memoryFile, all);
  return item;
}

async function clearUserMemory(userId) {
  if (supabase) {
    const { error } = await supabase.from('megan_memories').delete().eq('user_id', userId);
    if (!error) return true;
    console.error('Erro ao limpar memória no Supabase:', error.message);
  }

  const all = readJson(memoryFile, {});
  all[userId] = [];
  writeJson(memoryFile, all);
  return true;
}

function extractStructuredMemories(message) {
  const text = sanitizeText(message, 3000);
  const lower = text.toLowerCase();
  const facts = [];

  const add = (key, value, category = 'profile', importance = 'high') => {
    const cleaned = cleanFactValue(value);
    if (!cleaned || cleaned.length < 2) return;
    facts.push({ key, value: cleaned, category, importance });
  };

  const patterns = [
    { key: 'name', category: 'identity', re: /(?:meu nome é|me chamo|pode me chamar de)\s+([^\n,.!?]+)/i },
    { key: 'project', category: 'work', re: /(?:estou criando|estou desenvolvendo|estou fazendo|meu projeto é|o projeto é)\s+([^\n.!?]+)/i },
    { key: 'preference', category: 'preference', re: /(?:eu prefiro|prefiro|gosto de|quero que você)\s+([^\n.!?]+)/i },
    { key: 'goal', category: 'goal', re: /(?:meu objetivo é|minha meta é|quero alcançar|quero criar)\s+([^\n.!?]+)/i },
    { key: 'business', category: 'business', re: /(?:minha empresa é|trabalho com|meu negócio é|meu negocio é)\s+([^\n.!?]+)/i },
    { key: 'app_name', category: 'project', re: /(?:nome do app é|app se chama|aplicativo se chama)\s+([^\n.!?]+)/i },
  ];

  for (const item of patterns) {
    const match = text.match(item.re);
    if (match?.[1]) add(item.key, match[1], item.category, 'high');
  }

  if (lower.includes('megan life')) add('current_project', 'Megan Life', 'project', 'high');
  if (lower.includes('megan os')) add('current_project', 'Megan OS', 'project', 'high');
  if (lower.includes('voz feminina')) add('voice_preference', 'voz feminina', 'preference', 'medium');
  if (lower.includes('voz masculina')) add('voice_preference', 'voz masculina', 'preference', 'medium');
  if (lower.includes('render')) add('deployment_platform', 'Render', 'technical', 'medium');
  if (lower.includes('supabase')) add('database_platform', 'Supabase', 'technical', 'medium');
  if (lower.includes('android studio')) add('development_tool', 'Android Studio', 'technical', 'medium');

  const unique = new Map();
  for (const fact of facts) unique.set(`${fact.key}:${fact.value.toLowerCase()}`, fact);
  return Array.from(unique.values()).slice(0, 12);
}

async function saveIntelligentMemories(userId, message, device) {
  const facts = extractStructuredMemories(message);
  for (const fact of facts) {
    await addMemoryItem(userId, 'profile_fact', `${fact.key}: ${fact.value}`, {
      type: 'profile_fact',
      key: fact.key,
      value: fact.value,
      category: fact.category,
      importance: fact.importance,
      source: 'auto_extractor',
      device
    });
  }
  return facts;
}

function buildProfileFromMemory(memory) {
  const profile = {};
  const facts = memory.filter((item) => item.metadata?.type === 'profile_fact');

  for (const item of facts) {
    const key = item.metadata?.key;
    const value = item.metadata?.value;
    if (!key || !value) continue;
    profile[key] = {
      value,
      category: item.metadata?.category || 'profile',
      importance: item.metadata?.importance || 'medium',
      updatedAt: item.at
    };
  }

  return profile;
}

function buildMemoryDigest(memory) {
  const profile = buildProfileFromMemory(memory);
  const recent = memory
    .filter((item) => ['user', 'assistant', 'file_analysis', 'health_summary', 'athlete_summary'].includes(item.role))
    .slice(-CHAT_RECENT_LIMIT)
    .map((item) => ({
      role: item.role,
      content: sanitizeText(item.content, 700),
      at: item.at
    }));

  return { profile, recent };
}

async function askGemini(system, prompt, context = {}) {
  if (!ai) return 'Gemini ainda não está configurado. Configure GEMINI_API_KEY no Render em Environment.';

  const safeSystem = sanitizeText(system, 6000);
  const safePrompt = sanitizeText(prompt, 12000);
  const safeContext = JSON.stringify(context || {}, null, 2).slice(0, 18000);

  const response = await ai.models.generateContent({
    model,
    contents: `${safeSystem}

REGRAS DE ESTABILIDADE:
- Responda apenas uma vez.
- Não repita frases, blocos ou listas.
- Se o pedido estiver confuso, faça uma pergunta curta de esclarecimento.
- Use o contexto somente quando ele for necessário para responder.
- Não misture assuntos antigos com o pedido atual.

Contexto inteligente da Megan:
${safeContext}

Pedido atual do usuário:
${safePrompt}`,
    generationConfig: {
      temperature: Number(process.env.GEMINI_TEMPERATURE || 0.45),
      topP: Number(process.env.GEMINI_TOP_P || 0.85),
      topK: Number(process.env.GEMINI_TOP_K || 40),
      maxOutputTokens: Number(process.env.GEMINI_MAX_OUTPUT_TOKENS || 2048)
    }
  });

  return dedupeRepeatedLines(response.text || 'Não consegui responder agora.');
}


async function askGeminiMultimodal(system, prompt, file, context = {}) {
  if (!ai) return 'Gemini ainda não está configurado. Configure GEMINI_API_KEY no Render em Environment.';

  const mime = file.mimetype || 'application/octet-stream';
  const base64 = file.buffer.toString('base64');
  const response = await ai.models.generateContent({
    model,
    contents: [
      {
        role: 'user',
        parts: [
          {
            text: `${system}\n\nContexto inteligente da Megan:\n${JSON.stringify(context, null, 2)}\n\nPedido do usuário:\n${prompt}`
          },
          {
            inlineData: {
              mimeType: mime,
              data: base64
            }
          }
        ]
      }
    ]
  });

  return formatTextChatGPTStyle(response.text || 'Não consegui analisar a imagem agora.');
}

function isImageFile(file) {
  const name = (file.originalname || '').toLowerCase();
  const mime = file.mimetype || '';
  return mime.startsWith('image/') || /\.(png|jpg|jpeg|webp|bmp|gif|tiff)$/i.test(name);
}

function isSpreadsheetFile(file) {
  const name = (file.originalname || '').toLowerCase();
  const mime = file.mimetype || '';
  return /\.(xlsx|xls|ods)$/i.test(name) || mime.includes('spreadsheet') || mime.includes('excel');
}

function makeSafeFileName(name, fallback = 'arquivo') {
  const base = String(name || fallback)
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '')
    .slice(0, 80);
  return base || fallback;
}

function publicDownloadUrl(req, fileName) {
  const protocol = req.headers['x-forwarded-proto'] || req.protocol || 'https';
  return `${protocol}://${req.get('host')}/downloads/${encodeURIComponent(fileName)}`;
}

function normalizeImagePrompt(value) {
  const prompt = sanitizeText(value, 4000);
  if (!prompt) {
    return 'Crie uma imagem premium, futurista e profissional da Megan Life, uma assistente inteligente com visual moderno, luzes suaves, tecnologia avançada e estilo cinematográfico.';
  }
  return prompt;
}

async function generateOpenAiImage(prompt) {
  const apiKey = process.env.OPENAI_API_KEY || '';
  if (!apiKey) {
    const error = new Error('OPENAI_API_KEY não configurada no Render.');
    error.statusCode = 503;
    throw error;
  }

  const modelName = process.env.OPENAI_IMAGE_MODEL || 'gpt-image-1';
  const size = process.env.OPENAI_IMAGE_SIZE || '1024x1024';

  const response = await fetch('https://api.openai.com/v1/images/generations', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: modelName,
      prompt: normalizeImagePrompt(prompt),
      size,
    }),
  });

  const raw = await response.text();
  let data = null;

  try {
    data = JSON.parse(raw);
  } catch (_) {
    const error = new Error('OpenAI retornou uma resposta inválida.');
    error.statusCode = 502;
    error.raw = raw.slice(0, 500);
    throw error;
  }

  if (!response.ok) {
    const error = new Error(data?.error?.message || 'Erro ao gerar imagem na OpenAI.');
    error.statusCode = response.status;
    throw error;
  }

  const item = Array.isArray(data?.data) ? data.data[0] : null;
  const image = item?.b64_json || item?.base64 || '';
  const url = item?.url || '';

  if (!image && !url) {
    const error = new Error('OpenAI não retornou imagem.');
    error.statusCode = 502;
    throw error;
  }

  return { image, url, model: modelName, size };
}


function cleanPdfText(value, max = 50000) {
  return sanitizeText(value, max)
    .replace(/\r/g, '')
    .replace(/\u2022/g, '-')
    .replace(/[\u2013\u2014]/g, '-')
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/[\u00A0]/g, ' ')
    .replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, '')
    .replace(/[\u2600-\u27BF]/g, '')
    .replace(/[^\x09\x0A\x0D\x20-\x7E\xA0-\xFF]/g, '')
    .replace(/[ \t]{2,}/g, ' ')
    .trim();
}

function splitPdfLine(line, max = 88) {
  const clean = cleanPdfText(line, 2000);
  if (!clean) return [''];

  const words = clean.split(/\s+/);
  const lines = [];
  let current = '';

  for (const word of words) {
    if (!current) {
      current = word;
      continue;
    }

    if ((current.length + word.length + 1) > max) {
      lines.push(current);
      current = word;
    } else {
      current += ` ${word}`;
    }
  }

  if (current) lines.push(current);
  return lines.length ? lines : [''];
}

function writeTextPdf(title, body) {
  return PDFDocument.create().then(async (pdf) => {
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    let page = pdf.addPage([595, 842]);
    let y = 790;

    const safeTitle = cleanPdfText(title, 120) || 'Arquivo Megan Life';
    page.drawText(safeTitle, { x: 40, y, size: 18, font: bold });
    y -= 34;

    const cleanBody = cleanPdfText(body, 50000) || 'Conteudo gerado pela Megan Life.';
    const lines = cleanBody.split('\n').flatMap((line) => splitPdfLine(line, 88));

    for (const rawLine of lines) {
      const line = cleanPdfText(rawLine, 1000);

      if (y < 50) {
        page = pdf.addPage([595, 842]);
        y = 790;
      }

      page.drawText(line || ' ', { x: 40, y, size: 10, font });
      y -= 14;
    }

    return Buffer.from(await pdf.save());
  });
}

async function writeDocx(title, body) {
  const paragraphs = [
    new Paragraph({
      children: [new TextRun({ text: sanitizeText(title, 120) || 'Arquivo Megan Life', bold: true, size: 32 })],
    }),
    new Paragraph(''),
    ...sanitizeText(body, 50000).split('\n').map((line) => new Paragraph({ text: line || ' ' })),
  ];

  const doc = new Document({ sections: [{ children: paragraphs }] });
  return Packer.toBuffer(doc);
}

function readSpreadsheetText(file) {
  const workbook = xlsx.read(file.buffer, { type: 'buffer', cellDates: true });
  const parts = [];

  for (const sheetName of workbook.SheetNames.slice(0, 20)) {
    const sheet = workbook.Sheets[sheetName];
    const csv = xlsx.utils.sheet_to_csv(sheet, { blankrows: false });
    parts.push(`\n--- Planilha: ${sheetName} ---\n${csv.slice(0, 30000)}`);
  }

  return parts.join('\n').trim() || 'Planilha recebida, mas não encontrei dados legíveis.';
}

async function readFileText(file) {
  const name = file.originalname || 'arquivo';
  const mime = file.mimetype || 'application/octet-stream';
  const lower = name.toLowerCase();
  const buffer = file.buffer;

  if (mime === 'application/pdf' || lower.endsWith('.pdf')) {
    const parsed = await pdfParse(buffer);
    return parsed.text || '';
  }

  if (lower.endsWith('.docx')) {
    const result = await mammoth.extractRawText({ buffer });
    return result.value || '';
  }

  if (isSpreadsheetFile(file)) {
    return readSpreadsheetText(file);
  }

  if (lower.endsWith('.zip') || mime.includes('zip')) {
    const zip = await JSZip.loadAsync(buffer);
    const parts = [];

    for (const entry of Object.values(zip.files).filter((item) => !item.dir).slice(0, 120)) {
      const eLower = entry.name.toLowerCase();
      if (/\.(txt|md|json|csv|xml|html|js|ts|dart|java|kt|py|css|gradle|yaml|yml|env|sql)$/i.test(eLower)) {
        const content = await entry.async('string');
        parts.push(`\n--- ${entry.name} ---\n${content.slice(0, 30000)}`);
      } else {
        parts.push(`\n--- ${entry.name} ---\nArquivo listado dentro do ZIP. Leitura textual automática não aplicada a este formato.`);
      }
    }

    return parts.join('\n');
  }

  if (mime.startsWith('image/') || /\.(png|jpg|jpeg|webp|bmp|tiff)$/i.test(lower)) {
    const worker = await createWorker('por+eng');
    try {
      const result = await worker.recognize(buffer);
      return result.data?.text || 'Imagem recebida. Nenhum texto detectado por OCR.';
    } finally {
      await worker.terminate();
    }
  }

  if (/\.(txt|md|json|csv|xml|html|js|ts|dart|java|kt|py|css|gradle|yaml|yml|env|sql)$/i.test(lower) || mime.startsWith('text/')) {
    return buffer.toString('utf8');
  }

  return `Arquivo recebido: ${name}. Tipo: ${mime}. Ainda não foi possível extrair texto automaticamente deste formato.`;
}

app.get('/', (_req, res) => {
  res.json({
    ok: true,
    app: 'Megan Life',
    version: '4.2.3',
    status: 'online',
    memory: supabase ? 'supabase' : 'json-fallback',
    tts: Boolean(ttsClient)
  });
});

app.get('/api/health', (_req, res) => {
  res.json({
    ok: true,
    app: 'Megan Life',
    version: '4.2.3',
    gemini: Boolean(ai),
    memory: supabase ? 'supabase' : 'json-fallback',
    tts: Boolean(ttsClient)
  });
});

app.post('/api/tts', async (req, res) => {
  try {
    if (!ttsClient) {
      return res.status(503).json({
        ok: false,
        error: 'Google Cloud TTS não configurado no backend.'
      });
    }

    const text = sanitizeText(req.body?.text || '', 4500);

    if (!text) {
      return res.status(400).json({
        ok: false,
        error: 'Texto vazio.'
      });
    }

    const useSsml = req.body?.ssml !== false;
    const request = {
      input: useSsml ? { ssml: buildHumanSsml(text) } : { text },
      voice: {
        languageCode: process.env.GOOGLE_CLOUD_TTS_LANGUAGE || 'pt-BR',
        name: process.env.GOOGLE_CLOUD_TTS_VOICE || 'pt-BR-Neural2-A',
        ssmlGender: process.env.GOOGLE_CLOUD_TTS_GENDER || 'FEMALE',
      },
      audioConfig: {
        audioEncoding: 'MP3',
        speakingRate: Number(process.env.GOOGLE_CLOUD_TTS_RATE || 0.96),
        pitch: Number(process.env.GOOGLE_CLOUD_TTS_PITCH || 1.0),
        volumeGainDb: Number(process.env.GOOGLE_CLOUD_TTS_VOLUME_GAIN_DB || 0.0),
      },
    };

    const [response] = await ttsClient.synthesizeSpeech(request);

    if (!response.audioContent) {
      return res.status(500).json({
        ok: false,
        error: 'Google Cloud TTS não retornou áudio.'
      });
    }

    return res.json({
      ok: true,
      audio: Buffer.from(response.audioContent).toString('base64'),
      mimeType: 'audio/mpeg',
      encoding: 'base64'
    });
  } catch (e) {
    console.error('Erro no /api/tts:', e);
    return res.status(500).json({
      ok: false,
      error: e.message || 'Erro ao gerar áudio.'
    });
  }
});

app.post('/api/chat', async (req, res) => {
  const startedAt = Date.now();

  try {
    cleanupExpiredChatState();

    const { message = '', userId = 'luiz', device = 'android' } = req.body || {};
    const cleanMessage = sanitizeText(message, 12000);
    if (!cleanMessage) return res.status(400).json({ ok: false, error: 'Mensagem vazia.' });

    const normalizedMessage = normalizeForDuplicateCheck(cleanMessage);
    const lockKey = `${userId}:${normalizedMessage}`;
    const recent = recentChatMessages.get(lockKey);

    if (recent && Date.now() - recent.at < CHAT_DUPLICATE_WINDOW_MS) {
      return res.json({
        ok: true,
        answer: recent.answer || 'Já recebi essa mensagem. Pode continuar com a próxima informação.',
        duplicated: true,
        memoryMode: supabase ? 'supabase' : 'json-fallback'
      });
    }

    if (chatRequestLocks.has(lockKey)) {
      return res.json({
        ok: true,
        answer: 'Estou processando essa mensagem. Aguarde a resposta antes de enviar novamente.',
        processing: true,
        memoryMode: supabase ? 'supabase' : 'json-fallback'
      });
    }

    chatRequestLocks.set(lockKey, { createdAt: startedAt });

    const intelligentFacts = await saveIntelligentMemories(userId, cleanMessage, device);
    const historyAfterFacts = await getUserMemory(userId, CHAT_MEMORY_LIMIT);
    const memoryDigest = buildMemoryDigest(historyAfterFacts);

    let answer = await askGemini(
      `Você é Megan Life 4.2.3, assistente Android pessoal de Luiz.

PERSONALIDADE:
- Parceira, prática, inteligente, cuidadosa e objetiva.
- Responda em português do Brasil.

REGRAS PRINCIPAIS:
- Entenda primeiro o pedido atual.
- Não repita respostas.
- Não responda duas vezes a mesma coisa.
- Não misture assuntos antigos se o usuário não pediu.
- Use memória persistente apenas quando ajudar.
- Quando o usuário perguntar sobre nome, projeto, preferências ou histórico, responda usando a memória.
- Se o pedido estiver ambíguo, peça esclarecimento de forma curta.
- Saúde: nunca dê diagnóstico médico fechado; quando houver risco, oriente procurar médico.`,
      cleanMessage,
      { userId, device, memoryDigest }
    );

    answer = dedupeRepeatedLines(answer);

    if (!answer) {
      answer = 'Não consegui montar uma resposta clara agora. Pode reformular o pedido?';
    }

    const previousAnswer = recentChatAnswers.get(userId);
    const normalizedAnswer = normalizeForDuplicateCheck(answer);

    if (previousAnswer?.normalized === normalizedAnswer && Date.now() - previousAnswer.at < 60000) {
      answer = 'Para evitar repetir a mesma resposta, me diga qual parte você quer aprofundar ou qual próximo passo deseja seguir.';
    }

    await addMemoryItem(userId, 'user', cleanMessage, {
      type: 'conversation',
      importance: cleanMessage.length > 20 ? 'medium' : 'low',
      device
    });

    await addMemoryItem(userId, 'assistant', answer, {
      type: 'ai_response',
      importance: 'medium',
      device
    });

    const updatedHistory = await getUserMemory(userId, CHAT_MEMORY_LIMIT);

    recentChatMessages.set(lockKey, {
      at: Date.now(),
      answer
    });

    recentChatAnswers.set(userId, {
      at: Date.now(),
      normalized: normalizeForDuplicateCheck(answer)
    });

    res.json({
      ok: true,
      answer,
      memoryItems: updatedHistory.length,
      memoryMode: supabase ? 'supabase' : 'json-fallback',
      learnedFacts: intelligentFacts
    });
  } catch (e) {
    console.error('Erro no /api/chat:', e);
    res.status(500).json({ ok: false, error: e.message });
  } finally {
    try {
      const { message = '', userId = 'luiz' } = req.body || {};
      const cleanMessage = sanitizeText(message, 12000);
      const lockKey = `${userId}:${normalizeForDuplicateCheck(cleanMessage)}`;
      chatRequestLocks.delete(lockKey);
    } catch (_) {}
  }
});

app.post('/api/memory/remember', async (req, res) => {
  try {
    const { userId = 'luiz', key = 'note', value = '', category = 'manual', importance = 'high' } = req.body || {};
    const cleanValue = cleanFactValue(value);
    if (!cleanValue) return res.status(400).json({ ok: false, error: 'Valor da memória vazio.' });
    const item = await addMemoryItem(userId, 'profile_fact', `${key}: ${cleanValue}`, {
      type: 'profile_fact',
      key,
      value: cleanValue,
      category,
      importance,
      source: 'manual'
    });
    res.json({ ok: true, item });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.get('/api/profile/:userId', async (req, res) => {
  try {
    const memory = await getUserMemory(req.params.userId, 300);
    res.json({ ok: true, memoryMode: supabase ? 'supabase' : 'json-fallback', profile: buildProfileFromMemory(memory) });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.post('/api/generate-image', async (req, res) => {
  try {
    const prompt = normalizeImagePrompt(req.body?.prompt || req.body?.message || '');
    const result = await generateOpenAiImage(prompt);

    return res.json({
      ok: true,
      message: 'Imagem gerada com sucesso.',
      image: result.image,
      imageUrl: result.url,
      mime: 'image/png',
      model: result.model,
      size: result.size,
    });
  } catch (e) {
    console.error('Erro no /api/generate-image:', e);
    return res.status(e.statusCode || 500).json({
      ok: false,
      error: e.message || 'Erro ao gerar imagem.',
    });
  }
});

app.post('/api/files/analyze', upload.single('file'), async (req, res) => {
  try {
    if (!req.file) return res.status(400).json({ ok: false, error: 'Arquivo não enviado.' });

    const userId = req.body?.userId || 'luiz';
    const text = await readFileText(req.file);
    const history = await getUserMemory(userId, 140);
    const memoryDigest = buildMemoryDigest(history);
    const prompt = `Analise este arquivo com profundidade. Se for exame médico, compare sinais de melhora ou piora quando houver valores anteriores, explique em linguagem simples e oriente procurar médico se houver algo preocupante. Não dê diagnóstico fechado.\n\nNome: ${req.file.originalname}\nTipo: ${req.file.mimetype}\nTamanho: ${req.file.size}\n\nTexto extraído:\n${text.slice(0, 90000)}`;

    const answer = await askGemini(
      'Você é Megan Life 4.2.3 analisando arquivos, exames, imagens e ZIPs com responsabilidade.',
      prompt,
      { userId, memoryDigest }
    );

    await addMemoryItem(userId, 'file_analysis', `Arquivo analisado: ${req.file.originalname}\nResumo: ${answer.slice(0, 2000)}`, {
      type: 'file_analysis',
      fileName: req.file.originalname,
      mime: req.file.mimetype,
      sizeBytes: req.file.size,
      importance: 'medium'
    });

    res.json({
      ok: true,
      file: { name: req.file.originalname, mime: req.file.mimetype, sizeBytes: req.file.size },
      extractedPreview: cleanMeganOutput(text, 4000),
      answer
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});


app.post('/api/images/analyze', upload.single('file'), async (req, res) => {
  try {
    if (!req.file) return res.status(400).json({ ok: false, error: 'Imagem não enviada.' });
    if (!isImageFile(req.file)) return res.status(400).json({ ok: false, error: 'O arquivo enviado não parece ser uma imagem.' });

    const userId = req.body?.userId || 'luiz';
    const question = sanitizeText(req.body?.question || 'Descreva a imagem, identifique objetos, contexto, possíveis textos visíveis e detalhes importantes.', 3000);
    const history = await getUserMemory(userId, 140);
    const memoryDigest = buildMemoryDigest(history);

    let ocrText = '';
    try {
      ocrText = await readFileText(req.file);
    } catch (e) {
      ocrText = `OCR indisponível: ${e.message}`;
    }

    const prompt = `${question}\n\nNome da imagem: ${req.file.originalname}\nTipo: ${req.file.mimetype}\nTamanho: ${req.file.size}\n\nTexto detectado por OCR, se houver:\n${sanitizeText(ocrText, 12000)}`;

    const answer = await askGeminiMultimodal(
      'Você é Megan Life analisando imagens como um assistente visual. Descreva com clareza o que aparece, identifique objetos, telas, erros, documentos e textos visíveis. Se for print de erro técnico, explique o provável problema e próximos passos. Não identifique pessoas reais por nome.',
      prompt,
      req.file,
      { userId, memoryDigest }
    );

    await addMemoryItem(userId, 'file_analysis', `Imagem analisada: ${req.file.originalname}\nResumo: ${answer.slice(0, 2000)}`, {
      type: 'image_analysis',
      fileName: req.file.originalname,
      mime: req.file.mimetype,
      sizeBytes: req.file.size,
      importance: 'medium'
    });

    res.json({
      ok: true,
      file: { name: req.file.originalname, mime: req.file.mimetype, sizeBytes: req.file.size },
      ocrPreview: cleanMeganOutput(ocrText, 4000),
      answer
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});


app.get('/api/files/generate', (_req, res) => {
  res.status(405).json({
    ok: false,
    error: 'Use POST /api/files/generate para gerar arquivos.',
    example: {
      type: 'pdf',
      title: 'Arquivo Megan Life',
      content: 'Conteudo do PDF'
    }
  });
});

app.post('/api/files/generate', async (req, res) => {
  try {
    const type = sanitizeText(req.body?.type || 'txt', 20).toLowerCase().replace('.', '');
    const title = sanitizeText(req.body?.title || 'Arquivo Megan Life', 160);
    const content = formatTextChatGPTStyle(req.body?.content || req.body?.body || '', 90000) || 'Conteúdo gerado pela Megan Life.';
    const baseName = makeSafeFileName(req.body?.fileName || title || 'megan-life-arquivo');
    const stamp = new Date().toISOString().replace(/[-:.TZ]/g, '').slice(0, 14);
    const allowed = ['txt', 'md', 'json', 'csv', 'pdf', 'docx', 'zip'];
    const finalType = allowed.includes(type) ? type : 'txt';
    const fileName = `${baseName}-${stamp}.${finalType}`;
    const filePath = path.join(generatedDir, fileName);

    ensureDataDir();

    if (finalType === 'pdf') {
      fs.writeFileSync(filePath, await writeTextPdf(title, content));
    } else if (finalType === 'docx') {
      fs.writeFileSync(filePath, await writeDocx(title, content));
    } else if (finalType === 'json') {
      let payload;
      try {
        payload = JSON.parse(content);
      } catch (_) {
        payload = { title, content, generatedBy: 'Megan Life', createdAt: new Date().toISOString() };
      }
      fs.writeFileSync(filePath, JSON.stringify(payload, null, 2), 'utf8');
    } else if (finalType === 'csv') {
      fs.writeFileSync(filePath, content, 'utf8');
    } else if (finalType === 'zip') {
      const zip = new JSZip();
      zip.file('conteudo.txt', content);
      zip.file('metadata.json', JSON.stringify({ title, generatedBy: 'Megan Life', createdAt: new Date().toISOString() }, null, 2));
      const bytes = await zip.generateAsync({ type: 'nodebuffer' });
      fs.writeFileSync(filePath, bytes);
    } else {
      fs.writeFileSync(filePath, content, 'utf8');
    }

    res.json({
      ok: true,
      fileName,
      type: finalType,
      mime: finalType === 'pdf'
        ? 'application/pdf'
        : finalType === 'docx'
          ? 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
          : finalType === 'zip'
            ? 'application/zip'
            : 'text/plain',
      url: publicDownloadUrl(req, fileName),
      message: `Arquivo ${fileName} gerado com sucesso.`
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.post('/api/health/summary', async (req, res) => {
  try {
    const userId = req.body?.userId || 'luiz';
    const history = await getUserMemory(userId, 140);
    const answer = await askGemini(
      'Você é Megan Life 4.2.3. Analise saúde, relógio smart e performance esportiva sem diagnóstico fechado.',
      `Gere um resumo de saúde/performance com alertas responsáveis, melhorias, pioras e próximos passos. Dados: ${JSON.stringify(req.body, null, 2)}`,
      { userId, memoryDigest: buildMemoryDigest(history) }
    );
    await addMemoryItem(userId, 'health_summary', answer, { type: 'health_summary', metrics: req.body?.metrics || req.body, importance: 'high' });
    res.json({ ok: true, answer });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.post('/api/athlete/summary', async (req, res) => {
  try {
    const userId = req.body?.userId || 'luiz';
    const history = await getUserMemory(userId, 140);
    const answer = await askGemini(
      'Você é Megan Life 4.2.3, módulo de atleta. Analise desempenho, recuperação, sono, frequência cardíaca, volume e intensidade.',
      `Analise desempenho atlético e dê recomendações seguras: ${JSON.stringify(req.body, null, 2)}`,
      { userId, memoryDigest: buildMemoryDigest(history) }
    );
    await addMemoryItem(userId, 'athlete_summary', answer, { type: 'athlete_summary', metrics: req.body?.metrics || req.body, importance: 'high' });
    res.json({ ok: true, answer });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.get('/api/memory/:userId', async (req, res) => {
  try {
    const memory = await getUserMemory(req.params.userId, 300);
    res.json({ ok: true, memoryMode: supabase ? 'supabase' : 'json-fallback', memory, profile: buildProfileFromMemory(memory) });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.delete('/api/memory/:userId', async (req, res) => {
  try {
    await clearUserMemory(req.params.userId);
    res.json({ ok: true, message: 'Memória limpa.' });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.post('/api/feedback', async (req, res) => {
  try {
    const userId = req.body?.userId || 'luiz';
    const feedback = req.body?.feedback || req.body?.message || '';

    if (supabase) {
      await supabase.from('megan_feedback').insert({ user_id: userId, feedback, payload: req.body || {} });
    } else {
      const list = readJson(feedbackFile, []);
      list.push({ ...req.body, at: new Date().toISOString() });
      writeJson(feedbackFile, list.slice(-500));
    }

    await addMemoryItem(userId, 'feedback', feedback, { type: 'feedback', importance: 'medium' });
    res.json({ ok: true, message: 'Sugestão registrada.' });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.post('/api/reports/pdf', async (req, res) => {
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595, 842]);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  page.drawText(req.body?.title || 'Relatório Megan Life 4.2.3', { x: 40, y: 790, size: 18, font });
  const body = (req.body?.body || JSON.stringify(req.body, null, 2)).toString().slice(0, 3500);
  body.match(/.{1,90}/g)?.forEach((line, i) => page.drawText(line, { x: 40, y: 750 - i * 14, size: 10, font }));
  const bytes = await pdf.save();
  res.setHeader('Content-Type', 'application/pdf');
  res.send(Buffer.from(bytes));
});

app.post('/api/reports/zip', async (req, res) => {
  const zip = new JSZip();
  zip.file('megan-life-relatorio.json', JSON.stringify(req.body || {}, null, 2));
  zip.file('README.txt', 'Pacote gerado pela Megan Life 4.2.3.');
  const bytes = await zip.generateAsync({ type: 'uint8array' });
  res.setHeader('Content-Type', 'application/zip');
  res.send(Buffer.from(bytes));
});

app.listen(port, () => console.log(`Megan Life 4.2.3 backend rodando na porta ${port}`));