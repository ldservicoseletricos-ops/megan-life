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
const { GoogleGenAI } = require('@google/genai');
const { createClient } = require('@supabase/supabase-js');
const textToSpeech = require('@google-cloud/text-to-speech');

const app = express();
const port = Number(process.env.PORT || 10000);
const model = process.env.GEMINI_MODEL || 'gemini-2.5-flash';
const ai = process.env.GEMINI_API_KEY ? new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY }) : null;

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

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: Number(process.env.MAX_UPLOAD_MB || 50) * 1024 * 1024 }
});

app.disable('x-powered-by');
app.use(cors({ origin: true }));
app.use(express.json({ limit: '10mb' }));

function ensureDataDir() {
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
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
    .slice(-30)
    .map((item) => ({ role: item.role, content: sanitizeText(item.content, 1000), at: item.at }));

  return { profile, recent };
}

async function askGemini(system, prompt, context = {}) {
  if (!ai) return 'Gemini ainda não está configurado. Configure GEMINI_API_KEY no Render em Environment.';

  const response = await ai.models.generateContent({
    model,
    contents: `${system}\n\nContexto inteligente da Megan:\n${JSON.stringify(context, null, 2)}\n\nPedido do usuário:\n${prompt}`
  });

  return response.text || 'Não consegui responder agora.';
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
  try {
    const { message = '', userId = 'luiz', device = 'android' } = req.body || {};
    const cleanMessage = sanitizeText(message, 12000);
    if (!cleanMessage) return res.status(400).json({ ok: false, error: 'Mensagem vazia.' });

    const historyBefore = await getUserMemory(userId, 180);
    const intelligentFacts = await saveIntelligentMemories(userId, cleanMessage, device);
    const historyAfterFacts = await getUserMemory(userId, 180);
    const memoryDigest = buildMemoryDigest(historyAfterFacts);

    const answer = await askGemini(
      'Você é Megan Life 4.2.3, assistente Android pessoal de Luiz. Seja parceira, prática, inteligente e cuidadosa. Use o perfil persistente, fatos importantes e memória recente para manter continuidade. Quando o usuário perguntar sobre nome, projeto, preferências ou histórico, responda usando a memória. Saúde: nunca dê diagnóstico médico fechado; quando houver risco, oriente procurar médico.',
      cleanMessage,
      { userId, device, memoryDigest }
    );

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

    const updatedHistory = await getUserMemory(userId, 180);
    res.json({
      ok: true,
      answer,
      memoryItems: updatedHistory.length,
      memoryMode: supabase ? 'supabase' : 'json-fallback',
      learnedFacts: intelligentFacts
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
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
      extractedPreview: text.slice(0, 4000),
      answer
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