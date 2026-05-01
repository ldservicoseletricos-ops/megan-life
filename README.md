# Megan Life 4.2.3 — Memória Inteligente Real

Este pacote mantém a base da 4.2 e ativa memória inteligente com Supabase.

## Inclui
- Chat preservado no app Flutter.
- Backend Render com Gemini.
- Memória persistente Supabase.
- Extração automática de fatos importantes:
  - nome do usuário;
  - projeto atual;
  - preferências;
  - metas;
  - ferramenta/plataforma usada.
- Rotas novas:
  - `GET /api/profile/:userId`
  - `POST /api/memory/remember`
  - `GET /api/memory/:userId`

## Render
Root Directory:
```text
backend-render
```
Build Command:
```text
npm install
```
Start Command:
```text
node server.js
```

## Variáveis obrigatórias
```text
GEMINI_API_KEY=
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
```

## Teste
Abra:
```text
https://megan-life.onrender.com/api/health
```
Depois envie uma mensagem no app:
```text
Meu nome é Luiz Rosa e estou criando a Megan Life.
```
E consulte:
```text
https://megan-life.onrender.com/api/memory/luiz
https://megan-life.onrender.com/api/profile/luiz
```
