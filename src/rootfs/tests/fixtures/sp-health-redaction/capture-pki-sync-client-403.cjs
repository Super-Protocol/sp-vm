// Replays the exact log sequence pki-sync-client emits on the secrets-403 path,
// through the same logger it uses (CommonPinoLog -> default pino(), one JSON
// object per line, .child(context).<level>(msg)). The point of capturing rather
// than hand-writing is that pino owns the field set and the line length.
// pino stamps os.hostname(); pin it so the fixture reads as a swarm node
// rather than as whatever machine captured it. Nothing else is overridden --
// the field set, the line lengths and the interleaving are pino's own.
require('node:os').hostname = () => 'swarm-node-2';
const pino = require('pino');

class CommonPinoLog {
    constructor(level, baseContext = {}) {
        this.logger = pino();
        this.logger.level = level;
        this.baseContext = baseContext;
    }
    log(level, msg, context) {
        this.logger.child({ ...this.baseContext, ...context })[level](msg);
    }
    info(m, c) { this.log('info', m, c); }
    warn(m, c) { this.log('warn', m, c); }
    error(m, c) { this.log('error', m, c); }
    debug(m, c) { this.log('debug', m, c); }
    child(context) {
        return new CommonPinoLog(this.logger.level, { ...this.baseContext, ...context });
    }
}

const logger = new CommonPinoLog('debug', { service: 'SyncClient' });
const servers = ['10.77.0.4:9443', '10.77.0.5:9443'];
const challengeType = 'sev-snp';
const retryAttempts = 1;

logger.info('Resolved sync challenge configuration', {
    challengeType,
    networkID: 'mainnet',
    disableServerIdentityCheck: true,
    nvidiaTokenSupported: true,
    nvidiaTokenMode: 'auto-detect',
});
logger.warn('Server identity verification is disabled because disableServerIdentityCheck is enabled');
logger.info('Configured PKI authority CA bundle verified successfully');

for (const server of servers) {
    const serverLog = logger.child({ server, challengeType });
    serverLog.info('Trying sync server');
    serverLog.debug('Preparing PKI client for sync server', {
        disableServerIdentityCheck: true,
        useSystemRootCertificates: false,
    });
    serverLog.info('PKI client prepared successfully');
    serverLog.info(`POST attempt 1/${retryAttempts} for sync server`);
    // axios error.message for a 403 response, and evaluateRetry's reason
    // (`http-status:${httpStatus}`) -- sync-client.ts:212, :495.
    serverLog.error(
        `Failed attempt 1/${retryAttempts} for sync server: Request failed with status code 403. Reason: http-status:403`,
    );
    serverLog.error(
        'Error is not retryable for sync server; moving to next server. Reason: http-status:403',
    );
}
