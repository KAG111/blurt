const REGISTRY_APP_KEY = '4k3nlfhm';

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
      const res = await fetch(`https://keyvalue.immanuel.co/api/KeyVal/GetValue/${REGISTRY_APP_KEY}/room_bucket_${code}`);
      if (!res.ok) return { statusCode: res.status, body: '' };
      const val = (await res.text()).trim();
      return {
        statusCode: 200,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Content-Type': 'text/plain'
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

      // 2. Register on keyvalue.immanuel.co
      const regRes = await fetch(`https://keyvalue.immanuel.co/api/KeyVal/UpdateValue/${REGISTRY_APP_KEY}/room_bucket_${code}/${newBucketId}`, {
        method: 'POST'
      });
      if (!regRes.ok) {
        return { statusCode: regRes.status, body: 'Failed to register bucket' };
      }

      return {
        statusCode: 200,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Content-Type': 'text/plain'
        },
        body: newBucketId
      };
    } catch (e) {
      return { statusCode: 500, body: e.toString() };
    }
  }

  return { statusCode: 400, body: 'Invalid action' };
};
