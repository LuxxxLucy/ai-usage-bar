const { spawn } = require('node:child_process');

function normalize(result) {
    const now = Math.floor(Date.now() / 1000);
    const limits = result?.rateLimitsByLimitId
        ? result.rateLimitsByLimitId.codex
        : result?.rateLimits;
    if (limits?.limitId !== 'codex') throw new Error('Account limits unavailable');
    const windows = [limits.primary, limits.secondary].filter(
        window => window?.windowDurationMins === 10080);
    if (windows.length !== 1) throw new Error('Weekly limit unavailable');
    const { usedPercent: s, resetsAt: sr } = windows[0];
    if (!Number.isFinite(s) || s < 0 || s > 100 ||
        !Number.isInteger(sr) || sr <= now) {
        throw new Error('Invalid weekly limit');
    }
    return { s, sr, ts: now, state: 'ok' };
}

function readUsage() {
    return new Promise((resolve, reject) => {
        const child = spawn('codex', ['app-server'], {
            stdio: ['pipe', 'pipe', 'ignore'],
        });
        let buffer = '';
        let settled = false;
        const finish = (error, value) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            child.stdin.end();
            child.kill('SIGKILL');
            if (error) reject(error);
            else resolve(value);
        };
        const timer = setTimeout(() => finish(new Error('Account request timed out')), 10000);
        const send = message => child.stdin.write(JSON.stringify(message) + '\n');
        child.on('error', () => finish(new Error('Cannot start Codex')));
        child.on('exit', () => finish(new Error('Codex exited before responding')));
        child.stdin.on('error', () => finish(new Error('Codex connection failed')));
        child.stdout.on('data', data => {
            buffer += data.toString();
            let end;
            while (!settled && (end = buffer.indexOf('\n')) >= 0) {
                const line = buffer.slice(0, end);
                buffer = buffer.slice(end + 1);
                try {
                    const message = JSON.parse(line);
                    if (message.id !== 1 && message.id !== 2) continue;
                    if (message.error) throw new Error('Account request rejected');
                    if (message.id === 1) {
                        send({ method: 'initialized' });
                        send({ id: 2, method: 'account/rateLimits/read' });
                    } else {
                        finish(null, normalize(message.result));
                    }
                } catch (error) {
                    finish(error);
                }
            }
        });
        send({ id: 1, method: 'initialize', params: {
            clientInfo: { name: 'ai_usage_bar', version: '1.0' },
        } });
    });
}

readUsage().then(value => console.log(JSON.stringify(value))).catch(() => {
    console.error('Codex account usage unavailable');
    process.exitCode = 1;
});
