// Monitor sintético de punta a punta de Snippet Searcher (Scripted API, runtime Node.js 22).
// Lo arma Terraform con templatefile: lo que va entre $${...} lo completa synthetics.tf.
//
// 1. Pide un access token a Auth0 con client credentials (la aplicación M2M de los monitores).
// 2. Crea un snippet válido por la API pública, igual que la UI.
// 3. Lo lee y comprueba que vuelve el mismo código.
// 4. Lo borra, aunque haya fallado la lectura, para no dejar snippets de prueba.
//
// Si un paso falla, el check falla con el paso y el status en el mensaje.
const assert = require('assert');
const request = require('request');
const { promisify } = require('util');

const post = promisify(request.post);
const get = promisify(request.get);
const del = promisify(request.delete);

const BASE_URL = '${base_url}';
const CODE = 'let x: number = 5;\nprintln(x);';
// Que un servicio colgado no deje el check esperando para siempre.
const TIMEOUT_MS = 15000;

function expectStatus(step, response, expected) {
  assert.strictEqual(
    response.statusCode,
    expected,
    `$${step}: se esperaba $${expected} y respondió $${response.statusCode} $${JSON.stringify(response.body)}`,
  );
}

async function main() {
  const token = await post({
    url: 'https://${auth0_domain}/oauth/token',
    json: true,
    timeout: TIMEOUT_MS,
    body: {
      grant_type: 'client_credentials',
      client_id: '${client_id}',
      client_secret: $secure.${secret_key},
      audience: '${auth0_audience}',
    },
  });
  expectStatus('Token de Auth0', token, 200);
  const headers = { Authorization: `Bearer $${token.body.access_token}` };

  const created = await post({
    url: `$${BASE_URL}/api/snippets`,
    headers,
    json: true,
    timeout: TIMEOUT_MS,
    body: {
      name: `synthetic-$${Date.now()}`,
      description: 'Creado por el monitor sintético de New Relic; se borra solo',
      language: 'printscript',
      version: '1.1',
      content: CODE,
    },
  });
  expectStatus('Crear el snippet', created, 201);
  const id = created.body.id;
  console.log(`Snippet creado: $${id}`);

  try {
    const read = await get({ url: `$${BASE_URL}/api/snippets/$${id}`, headers, json: true, timeout: TIMEOUT_MS });
    expectStatus('Leer el snippet', read, 200);
    assert.strictEqual(read.body.content, CODE, 'Leer el snippet: el código no es el que se guardó');
  } finally {
    const deleted = await del({ url: `$${BASE_URL}/api/snippets/$${id}`, headers, timeout: TIMEOUT_MS });
    expectStatus('Borrar el snippet', deleted, 204);
  }
}

try {
  await main();
} catch (error) {
  console.error(error.message);
  throw error; // Hace fallar el check.
}
