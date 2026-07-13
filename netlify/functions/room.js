const MASTER_REGISTRY_URL = 'https://extendsclass.com/api/json-storage/bin/bacfaca';

exports.handler = async function(event, context) {
  // Support CORS preflight
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

  const { action, code } = event.queryStringParameters || {};

  if (action === 'get') {
    if (!code) return { statusCode: 400, body: 'Missing code' };
    try {
      const res = await fetch(MASTER_REGISTRY_URL);
      if (!res.ok) return { statusCode: res.status, body: '' };
      const registry = await res.json();
      const val = registry[code] || '';
      return {
        statusCode: 200,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Content-Type': 'text/plain',
          'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0'
        },
        body: val
      };
    } catch (e) {
      return { statusCode: 500, body: e.toString() };
    }
  }

  if (action === 'create') {
    if (!code) return { statusCode: 400, body: 'Missing code' };
    try {
      // 1. Create bucket on kvdb.io
      const res = await fetch('https://kvdb.io/', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'email=blurt-app-temp@antigravity.ai'
      });
      if (!res.ok) {
        return { statusCode: res.status, body: 'Failed to create bucket' };
      }
      const newBucketId = (await res.text()).trim();

      // 2. Register in the ExtendsClass master registry
      // We will perform a read-modify-write operation with a lock/retry pattern
      let registered = false;
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          const getRes = await fetch(MASTER_REGISTRY_URL);
          if (!getRes.ok) throw new Error('Failed to read registry');
          const registry = await getRes.json();
          
          // Add the new mapping
          registry[code] = newBucketId;

          // Clean up old entries if registry gets too big (e.g. keep last 200 rooms)
          const keys = Object.keys(registry);
          if (keys.length > 200) {
            // Delete the first 50 keys to keep it pruned
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
          // Wait briefly before retrying
          await new Promise(r => setTimeout(r, 200 * (attempt + 1)));
        }
      }

      if (!registered) {
        return { statusCode: 500, body: 'Failed to register bucket' };
      }

      return {
        statusCode: 200,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Content-Type': 'text/plain',
          'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0'
        },
        body: newBucketId
      };
    } catch (e) {
      return { statusCode: 500, body: e.toString() };
    }
  }

  return { statusCode: 400, body: 'Invalid action' };
};
