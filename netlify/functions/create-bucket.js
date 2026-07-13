exports.handler = async function(event, context) {
  // Support CORS preflight
  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'POST, OPTIONS'
      },
      body: ''
    };
  }

  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  try {
    const res = await fetch('https://kvdb.io/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'email=blurt-app-temp@antigravity.ai'
    });
    if (!res.ok) {
      return { 
        statusCode: res.status, 
        headers: { 'Access-Control-Allow-Origin': '*' },
        body: 'Failed to create bucket' 
      };
    }
    const bucketId = (await res.text()).trim();
    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Content-Type': 'text/plain'
      },
      body: bucketId
    };
  } catch (e) {
    return { 
      statusCode: 500, 
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: e.toString() 
    };
  }
};
