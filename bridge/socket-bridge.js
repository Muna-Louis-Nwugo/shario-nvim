#!/usr/bin/env node
// Thin relay between the Neovim plugin (Lua) and the real socket.io-client
// package. All the actual CRDT/docState logic lives in Lua; this process
// only knows how to open a socket.io connection and shuttle messages
// across it as newline-delimited JSON over stdio.
//
// stdin (Lua -> here), one JSON object per line:
//   {"cmd": "join", "path": "<dir>"}
//   {"cmd": "emit", "event": "ide-add", "data": {...}}
//   {"cmd": "disconnect"}
//
// stdout (here -> Lua), one JSON object per line:
//   {"event": "connect"}
//   {"event": "disconnect"}
//   {"event": "error", "message": "..."}
//   {"event": "<name>", "data": {...}}   -- any named event the server sent

const { io } = require('socket.io-client');
const readline = require('readline');

const args = process.argv.slice(2);
const portIdx = args.indexOf('--port');
const port = portIdx !== -1 ? args[portIdx + 1] : '3000';

function send(obj) {
    process.stdout.write(JSON.stringify(obj) + '\n');
}

const socket = io(`http://127.0.0.1:${port}`, { reconnection: true });

// connect/disconnect/connect_error are engine-level lifecycle events, not
// delivered through onAny (that only catches application events the
// server actually .emit()s) -- registered explicitly.
socket.on('connect', () => send({ event: 'connect' }));
socket.on('disconnect', () => send({ event: 'disconnect' }));
socket.on('connect_error', (err) => {
    send({ event: 'error', message: String((err && err.message) || err) });
});

// Everything else the server emits (initial-state, ide-add-confirmed,
// ide-add-failed, and anything added later) gets relayed as-is, so this
// bridge never needs updating just because the wire protocol grows a new
// event name.
socket.onAny((event, data) => send({ event, data }));

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try {
        msg = JSON.parse(line);
    } catch (e) {
        send({ event: 'error', message: `couldn't parse command: ${e.message}` });
        return;
    }

    if (msg.cmd === 'join') {
        socket.emit('join', { local: true, path: msg.path });
    } else if (msg.cmd === 'emit') {
        socket.emit(msg.event, msg.data);
    } else if (msg.cmd === 'disconnect') {
        socket.disconnect();
    }
});

rl.on('close', () => {
    // stdin closed (Lua side killed the job) -- nothing left to relay for
    socket.disconnect();
    process.exit(0);
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
