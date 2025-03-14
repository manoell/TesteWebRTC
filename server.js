const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');
const bodyParser = require('body-parser');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');

// Configurações
const PORT = process.env.PORT || 8080;
const LOGGING_ENABLED = true;
const LOG_FILE = './server.log';
const MAX_CONNECTIONS_PER_ROOM = 20;

// Inicializar aplicativo Express
const app = express();
app.use(cors());
app.use(bodyParser.json());
app.use(express.static(__dirname));

// Criar servidor HTTP e servidor WebSocket
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Armazenar conexões por sala
const rooms = {};
// Armazenar SDPs e ICE candidates
const roomData = {};
// Armazenar estatísticas de conexão
const roomStats = {};

/**
 * Função para logging com timestamp
 * @param {string} message - Mensagem para registro
 * @param {boolean} consoleOnly - Se true, registra apenas no console, não no arquivo
 */
const log = (message, consoleOnly = false) => {
    if (!LOGGING_ENABLED) return;
    
    const timestamp = new Date().toISOString();
    const logMessage = `[${timestamp}] ${message}`;
    
    console.log(logMessage);
    
    if (!consoleOnly && LOG_FILE) {
        fs.appendFile(LOG_FILE, logMessage + '\n', (err) => {
            if (err) console.error(`Erro ao escrever no log: ${err}`);
        });
    }
};

/**
 * Limpar dados antigos de salas vazias
 */
const cleanupEmptyRooms = () => {
    Object.keys(rooms).forEach(roomId => {
        if (!rooms[roomId] || rooms[roomId].length === 0) {
            log(`Limpando sala vazia: ${roomId}`);
            delete rooms[roomId];
            delete roomData[roomId];
            delete roomStats[roomId];
        }
    });
};

// Configurar intervalo para limpeza de dados antigos
setInterval(cleanupEmptyRooms, 60000); // A cada minuto

/**
 * Gera resumo de estatísticas para uma sala
 * @param {string} roomId - ID da sala
 * @returns {object} - Estatísticas da sala
 */
const getRoomStats = (roomId) => {
    if (!roomStats[roomId]) {
        roomStats[roomId] = {
            created: new Date(),
            connections: 0,
            messagesExchanged: 0,
            peakConnections: 0,
            lastActivity: new Date()
        };
    }
    
    return roomStats[roomId];
};

/**
 * Atualiza estatísticas da sala quando uma mensagem é processada
 * @param {string} roomId - ID da sala
 */
const updateRoomActivity = (roomId) => {
    const stats = getRoomStats(roomId);
    stats.messagesExchanged++;
    stats.lastActivity = new Date();
};

// Manipular conexões WebSocket
wss.on('connection', (ws) => {
    log('Nova conexão estabelecida via WebSocket');
    
    // Identificar cliente
    ws.id = uuidv4();
    ws.isAlive = true;
    let roomId = null;
    
    // Ping para manter conexão viva
    ws.on('pong', () => {
        ws.isAlive = true;
    });
    
    // Processar mensagens
    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            
            // Obter roomId da mensagem ou usar padrão
            const msgRoomId = data.roomId || 'default';
            
            if (data.type === 'join') {
				roomId = data.roomId || 'default';
				
				// Garantir que a sala exista
				if (!rooms[roomId]) {
					rooms[roomId] = [];
					roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
					console.log(`Nova sala criada: ${roomId}`);
				}
                
                // Limitar número de conexões por sala
                if (rooms[roomId].length >= MAX_CONNECTIONS_PER_ROOM) {
                    ws.send(JSON.stringify({
                        type: 'error',
                        message: 'Room is full'
                    }));
                    log(`Tentativa de conexão rejeitada - sala cheia: ${roomId}`, true);
                    return;
                }
                
                // Adicionar à sala
                rooms[roomId].push(ws);
                
                // Atualizar estatísticas
                const stats = getRoomStats(roomId);
                stats.connections++;
                stats.peakConnections = Math.max(stats.peakConnections, rooms[roomId].length);
                
                log(`Cliente ${ws.id} entrou na sala: ${roomId}, total na sala: ${rooms[roomId].length}`);
                
                // Notificar outros clientes
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({ 
                            type: 'user-joined',
                            userId: ws.id
                        }));
                    }
                });
                
                // Enviar dados existentes (ofertas e candidatos ICE)
                if (roomData[roomId].offers.length > 0) {
                    const latestOffer = roomData[roomId].offers[roomData[roomId].offers.length - 1];
                    ws.send(JSON.stringify(latestOffer));
                    log(`Enviando oferta existente para novo cliente ${ws.id}`);
                }
                
                if (roomData[roomId].iceCandidates.length > 0) {
                    roomData[roomId].iceCandidates.forEach(candidate => {
                        ws.send(JSON.stringify(candidate));
                    });
                    log(`Enviando ${roomData[roomId].iceCandidates.length} candidatos ICE para novo cliente ${ws.id}`);
                }
                
                // Enviar estatísticas da sala
                ws.send(JSON.stringify({
                    type: 'room-info',
                    clients: rooms[roomId].length,
                    room: roomId
                }));
            } 
            // Processar oferta SDP (otimizar para alta resolução)
            else if (data.type === 'offer' && roomId) {
                log(`Oferta SDP recebida de ${ws.id} na sala ${roomId}`);
                
                // Analisar qualidade da oferta para log
                if (data.sdp) {
                    const hasVideo = data.sdp.includes('m=video');
                    const hasAudio = data.sdp.includes('m=audio');
                    const hasH264 = data.sdp.includes('H264');
                    const hasVP8 = data.sdp.includes('VP8');
                    const hasVP9 = data.sdp.includes('VP9');
                    
                    log(`Qualidade da oferta: video=${hasVideo}, audio=${hasAudio}, H264=${hasH264}, VP8=${hasVP8}, VP9=${hasVP9}`, true);
                }
                
                // Armazenar oferta
                data.senderId = ws.id;
                data.timestamp = Date.now();
                roomData[roomId].offers.push(data);
                
                // Limitar número de ofertas armazenadas
                if (roomData[roomId].offers.length > 10) {
                    roomData[roomId].offers = roomData[roomId].offers.slice(-10);
                }
                
                // Encaminhar oferta para outros clientes
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(message);
                    }
                });
                
                updateRoomActivity(roomId);
            } 
            // Processar resposta SDP
            else if (data.type === 'answer' && roomId) {
                log(`Resposta SDP recebida de ${ws.id} na sala ${roomId}`);
                
                // Armazenar resposta
                data.senderId = ws.id;
                data.timestamp = Date.now();
                roomData[roomId].answers.push(data);
                
                // Limitar número de respostas armazenadas
                if (roomData[roomId].answers.length > 10) {
                    roomData[roomId].answers = roomData[roomId].answers.slice(-10);
                }
                
                // Encaminhar resposta para outros clientes
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(message);
                    }
                });
                
                updateRoomActivity(roomId);
            } 
            // Processar candidatos ICE
            else if (data.type === 'ice-candidate' && roomId) {
                log(`Candidato ICE recebido de ${ws.id}`);
                
                // Verificar se é um candidato duplicado
                const exists = roomData[roomId].iceCandidates.some(c => 
                    c.candidate === data.candidate && 
                    c.sdpMid === data.sdpMid && 
                    c.sdpMLineIndex === data.sdpMLineIndex
                );
                
                if (!exists) {
                    // Armazenar candidato
                    data.senderId = ws.id;
                    data.timestamp = Date.now();
                    roomData[roomId].iceCandidates.push(data);
                    
                    // Limitar número de candidatos armazenados
                    if (roomData[roomId].iceCandidates.length > 50) {
                        roomData[roomId].iceCandidates = roomData[roomId].iceCandidates.slice(-50);
                    }
                    
                    // Encaminhar candidato para outros clientes
                    rooms[roomId].forEach(client => {
                        if (client !== ws && client.readyState === WebSocket.OPEN) {
                            client.send(message);
                        }
                    });
                }
                
                updateRoomActivity(roomId);
            } 
            // Processar outras mensagens para a sala
            else if (roomId) {
                log(`Mensagem tipo "${data.type}" recebida de ${ws.id}`, true);
                
                // Encaminhar mensagem para outros clientes na sala
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(message);
                    }
                });
                
                updateRoomActivity(roomId);
            }
        } catch (e) {
            log(`Erro ao processar mensagem WebSocket: ${e.message}`);
            ws.send(JSON.stringify({
                type: 'error', 
                message: 'Invalid message format'
            }));
        }
    });
    
    // Manipular desconexão
    ws.on('close', () => {
        log(`Conexão com cliente ${ws.id} fechada`);
        
        if (roomId && rooms[roomId]) {
            // Remover cliente da sala
            rooms[roomId] = rooms[roomId].filter(client => client !== ws);
            log(`Cliente ${ws.id} saiu da sala: ${roomId}, restantes: ${rooms[roomId].length}`);
            
            // Atualizar estatísticas
            const stats = getRoomStats(roomId);
            stats.connections--;
            
            // Remover sala se vazia
            if (rooms[roomId].length === 0) {
                log(`Sala vazia: ${roomId} - será limpa na próxima verificação`);
            } else {
                // Notificar outros clientes sobre a saída
                rooms[roomId].forEach(client => {
                    if (client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({ 
                            type: 'user-left',
                            userId: ws.id
                        }));
                    }
                });
            }
        }
    });
});

// Configurar ping periódico para manter conexões vivas
const pingInterval = setInterval(() => {
    wss.clients.forEach(ws => {
        if (ws.isAlive === false) {
            log(`Terminando conexão inativa com ${ws.id}`);
            return ws.terminate();
        }
        
        ws.isAlive = false;
        ws.ping(() => {});
    });
}, 30000); // A cada 30 segundos

// Limpar intervalo quando o servidor é fechado
wss.on('close', () => {
    clearInterval(pingInterval);
});

// Endpoints REST para informações e diagnóstico

// Listar salas ativas
app.get('/api/rooms', (req, res) => {
    const roomsList = Object.keys(rooms).map(roomId => {
        const stats = getRoomStats(roomId);
        return {
            id: roomId,
            clients: rooms[roomId].length,
            created: stats.created,
            messagesExchanged: stats.messagesExchanged,
            lastActivity: stats.lastActivity
        };
    });
    
    res.json({ rooms: roomsList });
});

// Obter estatísticas de uma sala específica
app.get('/api/rooms/:roomId', (req, res) => {
    const roomId = req.params.roomId;
    
    if (!rooms[roomId]) {
        return res.status(404).json({ error: 'Room not found' });
    }
    
    const stats = getRoomStats(roomId);
    
    res.json({
        id: roomId,
        clients: rooms[roomId].length,
        stats: stats,
        offers: roomData[roomId].offers.length,
        answers: roomData[roomId].answers.length,
        iceCandidates: roomData[roomId].iceCandidates.length
    });
});

// Obter estado do servidor
app.get('/api/status', (req, res) => {
    res.json({
        status: 'running',
        uptime: process.uptime(),
        rooms: Object.keys(rooms).length,
        connections: Array.from(wss.clients).length,
        memoryUsage: process.memoryUsage()
    });
});

// Rota padrão para o cliente WebRTC
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// Iniciar servidor
server.listen(PORT, () => {
    log(`Servidor WebRTC rodando na porta ${PORT}`);
    log(`Interface web disponível em http://localhost:${PORT}`);
});