const MASTER_REGISTRY_URL = 'https://extendsclass.com/api/json-storage/bin/bacfaca';

exports.handler = async function(event, context) {
  // Support CORS preflight if called cross-origin, though we use it same-origin
  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
      },
      body: ''
    };
  }

  const { action, code, property } = event.queryStringParameters || {};

  // Helper to get bucket ID for room
  async function getBucketId(roomCode) {
    try {
      const res = await fetch(`${MASTER_REGISTRY_URL}?_cb=${Date.now()}`);
      if (!res.ok) return null;
      const registry = await res.json();
      return registry[roomCode] || null;
    } catch (e) {
      return null;
    }
  }

  if (action === 'get') {
    if (!code) return { statusCode: 400, body: 'Missing code' };
    try {
      const binId = await getBucketId(code);
      if (!binId) return { statusCode: 404, body: 'Room not found' };

      const res = await fetch(`https://extendsclass.com/api/json-storage/bin/${binId}?_cb=${Date.now()}`);
      if (!res.ok) return { statusCode: res.status, body: 'Failed to read bin' };
      const data = await res.text();
      return {
        statusCode: 200,
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0'
        },
        body: data
      };
    } catch (e) {
      return { statusCode: 500, body: e.toString() };
    }
  }

  if (action === 'create') {
    if (!code) return { statusCode: 400, body: 'Missing code' };
    const value = event.body;
    try {
      const initialData = {
        config: JSON.parse(value),
        words: [],
        posts: [],
        votes: [],
        responses: [],
        roster: []
      };

      // 1. Create a new bin on ExtendsClass
      const res = await fetch('https://extendsclass.com/api/json-storage/bin', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(initialData)
      });
      if (!res.ok) return { statusCode: res.status, body: 'Failed to create bin' };
      const resJson = await res.json();
      const binId = resJson.id;

      // 2. Register in master registry
      let registered = false;
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          const getRes = await fetch(`${MASTER_REGISTRY_URL}?_cb=${Date.now()}`);
          if (!getRes.ok) throw new Error();
          const registry = await getRes.json();
          registry[code] = binId;

          // Keep registry pruned
          const keys = Object.keys(registry);
          if (keys.length > 200) {
            for (let i = 0; i < 50; i++) {
              delete registry[keys[i]];
            }
          }

          const putRes = await fetch(MASTER_REGISTRY_URL, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(registry)
          });
          if (putRes.ok) {
            registered = true;
            break;
          }
        } catch (err) {
          await new Promise(r => setTimeout(r, 200 * (attempt + 1)));
        }
      }

      if (!registered) return { statusCode: 500, body: 'Failed to register bin' };

      return {
        statusCode: 200,
        headers: {
          'Content-Type': 'text/plain',
          'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0'
        },
        body: binId
      };
    } catch (e) {
      return { statusCode: 500, body: e.toString() };
    }
  }

  if (action === 'update') {
    if (!code || !property) return { statusCode: 400, body: 'Missing parameters' };
    const value = event.body;
    try {
      const binId = await getBucketId(code);
      if (!binId) return { statusCode: 404, body: 'Room not found' };

      let updated = false;
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          const getRes = await fetch(`https://extendsclass.com/api/json-storage/bin/${binId}?_cb=${Date.now()}`);
          if (!getRes.ok) throw new Error();
          const data = await getRes.json();

          let parsedVal;
          try {
            parsedVal = JSON.parse(value);
          } catch (e) {
            parsedVal = value;
          }
          data[property] = parsedVal;

          const putRes = await fetch(`https://extendsclass.com/api/json-storage/bin/${binId}`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
          });
          if (putRes.ok) {
            updated = true;
            break;
          }
        } catch (err) {
          await new Promise(r => setTimeout(r, 200 * (attempt + 1)));
        }
      }

      if (!updated) return { statusCode: 500, body: 'Failed to update bin' };

      return {
        statusCode: 200,
        headers: {
          'Content-Type': 'text/plain',
          'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0'
        },
        body: 'ok'
      };
    } catch (e) {
      return { statusCode: 500, body: e.toString() };
    }
  }

  return { statusCode: 400, body: 'Invalid action' };
};
