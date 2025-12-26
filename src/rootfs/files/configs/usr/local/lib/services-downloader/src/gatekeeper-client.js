const https = require('https');
const { URL } = require('url');

const getResourceFromGatekeeper = async (params) => {
  const { resourceName, branchName, sslKeyPem, sslCertPem } = params;
  const urlString = getUrl(resourceName, branchName, params.environment || 'mainnet');

  const agent = new https.Agent({
    key: sslKeyPem,
    cert: sslCertPem,
    rejectUnauthorized: true,
  });

  const buf = await new Promise((resolve, reject) => {
    try {
      const urlObj = new URL(urlString);

      const req = https.request(
        {
          protocol: urlObj.protocol,
          hostname: urlObj.hostname,
          port: urlObj.port,
          path: urlObj.pathname + urlObj.search,
          method: 'GET',
          headers: { Accept: 'application/json' },
          agent,
          timeout: params.timeout || 30000,
        },
        (res) => {
          const chunks = [];
          res.on('data', (chunk) => chunks.push(chunk));
          res.on('end', () => {
            const body = Buffer.concat(chunks);
            const ok = res.statusCode >= 200 && res.statusCode < 300;
            if (ok) {
              resolve(body);
            } else {
              const error = new Error(
                `Gatekeeper request failed: ${res.statusCode} ${
                  res.statusMessage
                } - ${body.toString('utf8')}`,
              );
              error.statusCode = res.statusCode;
              error.headers = res.headers;
              error.body = body;
              reject(error);
            }
          });
        },
      );

      req.on('error', reject);
      req.on('timeout', () => req.destroy(new Error('Request timed out')));
      req.end();
    } catch (e) {
      reject(e);
    }
  });

  return parseGatekeeperResourceResponse(buf);
};

function parseGatekeeperResourceResponse(buf) {
  let responseData;
  try {
    responseData = JSON.parse(buf.toString('utf8'));
  } catch (e) {
    const sample = buf.slice(0, 256).toString('utf8');
    throw new Error(`Invalid Gatekeeper response JSON: ${e.message}. Sample: ${sample}`);
  }

  // {
  //   resource: { type: 'STORJ', filepath: '...' },
  //   encryption: { key: 'hex', iv: 'hex' }
  // }
  const data = responseData.data;
  if (!data.resource || !data.encryption) {
    throw new Error('Gatekeeper response is invalid - missing resource or encryption field');
  }

  return data;
}

const getUrl = (resourceName, branchName, environment) => {
  const subdomain = `secrets-gatekeeper${environment === 'mainnet' ? '' : `-${environment}`}`;

  return `https://${subdomain}.superprotocol.io:44443/resources/${resourceName}/${branchName}`;
};

module.exports = { getResourceFromGatekeeper };
