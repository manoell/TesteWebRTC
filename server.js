const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');
const bodyParser = require('body-parser');
const { v4: uuidv4 } = require('uuid');

const app = express();
app.use(cors());
app.use(bodyParser.json());
// Alterado: usa o diretório atual em vez de 'public'
app.use(express.static(__dirname));

const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Armazenar conexões por sala
const rooms = {};
// Armazenar SDPs e ICE candidates
const roomData = {};

const log = (message) => {
    const timestamp = new Date().toLocaleString('pt-BR', { timeZone: 'UTC' });
    console.log(`[${timestamp}] ${message}`);
};

wss.on('connection', (ws) => {
    log('Nova conexão estabelecida via WebSocket');
    let roomId = null;

    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            log(`Mensagem WebSocket recebida: ${data.type} na sala ${roomId || 'não definida'}`);

            if (data.type === 'join') {
                roomId = data.roomId || 'default';
                if (!rooms[roomId]) rooms[roomId] = [];
                if (!roomData[roomId]) roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };

                rooms[roomId].push(ws);
                log(`Cliente WebSocket entrou na sala: ${roomId}, total na sala: ${rooms[roomId].length}`);

                // Notificar outros clientes
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({ type: 'user-joined' }));
                    }
                });

                // Enviar dados existentes
                if (roomData[roomId].offers.length > 0) {
                    roomData[roomId].offers.forEach(offer => ws.send(JSON.stringify(offer)));
                }
                if (roomData[roomId].iceCandidates.length > 0) {
                    roomData[roomId].iceCandidates.forEach(candidate => ws.send(JSON.stringify(candidate)));
                }
            } else if (data.type === 'offer') {
                if (!roomData[roomId]) roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
                roomData[roomId].offers = [data]; // Armazena apenas a oferta mais recente
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(message);
                    }
                });
            } else if (data.type === 'answer') {
                if (!roomData[roomId]) roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
                roomData[roomId].answers.push(data);
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(message);
                    }
                });
            } else if (data.type === 'ice-candidate') {
                if (!roomData[roomId]) roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
                const exists = roomData[roomId].iceCandidates.some(c => c.candidate === data.candidate);
                if (!exists) {
                    roomData[roomId].iceCandidates.push(data);
                    rooms[roomId].forEach(client => {
                        if (client !== ws && client.readyState === WebSocket.OPEN) {
                            client.send(message);
                        }
                    });
                }
            } else if (roomId) {
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(message);
                    }
                });
            }
        } catch (e) {
            log(`Erro ao processar mensagem WebSocket: ${e.message}`);
        }
    });

    ws.on('close', () => {
        log('Conexão WebSocket fechada');
        if (roomId && rooms[roomId]) {
            rooms[roomId] = rooms[roomId].filter(client => client !== ws);
            log(`Cliente WebSocket saiu da sala: ${roomId}, restantes: ${rooms[roomId].length}`);
            if (rooms[roomId].length === 0) {
                delete rooms[roomId];
                delete roomData[roomId];
                log(`Sala removida: ${roomId}`);
            } else {
                rooms[roomId].forEach(client => {
                    if (client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({ type: 'user-left' }));
                    }
                });
            }
        }
    });
});

app.get('/join', (req, res) => {
    const roomId = req.query.roomId || 'default';
    log(`Cliente REST solicitou ingresso na sala: ${roomId}`);
    if (!rooms[roomId]) rooms[roomId] = [];
    if (!roomData[roomId]) roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
    const clientId = uuidv4();
    log(`Cliente REST ${clientId} ingressou na sala ${roomId}`);
    const existingOffers = roomData[roomId].offers;
    res.json({ clientId, roomId, hasExistingOffers: existingOffers.length > 0 });
});

app.get('/offers', (req, res) => {
    const roomId = req.query.roomId || 'default';
    res.json({ offers: roomData[roomId]?.offers || [] });
});

app.post('/offer', (req, res) => {
    const roomId = req.query.roomId || 'default';
    const clientId = req.query.clientId;
    const sdp = req.body;
    if (!roomId || !clientId || !sdp) return res.status(400).json({ error: 'Room ID, Client ID and SDP are required' });
    log(`Recebendo oferta SDP do cliente ${clientId} para sala ${roomId}`);
    const offerData = { type: 'offer', sdp: sdp.sdp, clientId };
    if (!roomData[roomId]) roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
    roomData[roomId].offers.push(offerData);
    if (rooms[roomId]) rooms[roomId].forEach(client => client.readyState === WebSocket.OPEN && client.send(JSON.stringify(offerData)));
    res.json({ success: true });
});

app.post('/answer', (req, res) => {
    const roomId = req.query.roomId || 'default';
    const clientId = req.query.clientId;
    const sdp = req.body;
    if (!roomId || !clientId || !sdp) return res.status(400).json({ error: 'Room ID, Client ID and SDP are required' });
    log(`Recebendo resposta SDP do cliente ${clientId} para sala ${roomId}`);
    const answerData = { type: 'answer', sdp: sdp.sdp, clientId };
    if (!roomData[roomId]) roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
    roomData[roomId].answers.push(answerData);
    if (rooms[roomId]) rooms[roomId].forEach(client => client.readyState === WebSocket.OPEN && client.send(JSON.stringify(answerData)));
    res.json({ success: true });
});

app.post('/ice', (req, res) => {
    const roomId = req.query.roomId || 'default';
    const clientId = req.query.clientId;
    const candidate = req.body;
    if (!roomId || !clientId || !candidate) return res.status(400).json({ error: 'Room ID, Client ID and ICE candidate are required' });
    log(`Recebendo candidato ICE do cliente ${clientId} para sala ${roomId}`);
    const iceData = { type: 'ice-candidate', candidate: candidate.candidate, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, clientId };
    if (!roomData[roomId]) roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
    roomData[roomId].iceCandidates.push(iceData);
    if (rooms[roomId]) rooms[roomId].forEach(client => client.readyState === WebSocket.OPEN && client.send(JSON.stringify(iceData)));
    res.json({ success: true });
});

app.get('/ice', (req, res) => {
    const roomId = req.query.roomId || 'default';
    res.json({ candidates: roomData[roomId]?.iceCandidates || [] });
});

app.post('/leave', (req, res) => {
    const roomId = req.query.roomId || 'default';
    const clientId = req.query.clientId;
    if (!roomId || !clientId) return res.status(400).json({ error: 'Room ID and Client ID are required' });
    log(`Cliente REST ${clientId} está saindo da sala ${roomId}`);
    if (rooms[roomId]) rooms[roomId].forEach(client => client.readyState === WebSocket.OPEN && client.send(JSON.stringify({ type: 'user-left', clientId })));
    res.json({ success: true });
});

// Alterado: aponta diretamente para index.html no mesmo diretório
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

const PORT = process.env.PORT || 8080;
server.listen(PORT, () => {
    log(`Servidor rodando na porta ${PORT}`);
});