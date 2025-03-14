/**
 * Servidor WebRTC otimizado para transmissão em alta qualidade 4K/60fps
 * Focado em rede local com mínima latência
 */

const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const os = require('os');

// Configurações
const PORT = process.env.PORT || 8080;
const LOGGING_ENABLED = true;
const LOG_FILE = './server.log';
const MAX_CONNECTIONS = 2; // Limitado a transmissor + receptor
const KEEP_ALIVE_INTERVAL = 5000; // 5 segundos para detecção rápida de desconexões

// Inicializar aplicativo Express
const app = express();
app.use(cors({
    origin: '*',
    methods: ['GET', 'POST', 'DELETE']
}));
app.use(express.json());
app.use(express.static(__dirname));

// Criar servidor HTTP e servidor WebSocket
const server = http.createServer(app);
const wss = new WebSocket.Server({ 
    server,
    // Aumentar o tamanho máximo dos payloads para suportar vídeo 4K
    maxPayload: 64 * 1024 * 1024 // 64MB
});

// Armazenar conexões
const rooms = {};
const roomData = {};
const roomStats = {};
const clients = new Map();

/**
 * Função para logging com timestamp
 * @param {string} message - Mensagem para registro
 * @param {boolean} consoleOnly - Se true, registra apenas no console
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

// Configurar intervalo para limpeza de dados antigos (a cada minuto)
setInterval(cleanupEmptyRooms, 60000);

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
            lastActivity: new Date(),
            bandwidth: 0,
            resolution: "unknown"
        };
    }
    
    return roomStats[roomId];
};

/**
 * Atualiza estatísticas da sala quando uma mensagem é processada
 * @param {string} roomId - ID da sala
 * @param {number} messageSize - Tamanho da mensagem em bytes
 */
const updateRoomActivity = (roomId, messageSize = 0) => {
    const stats = getRoomStats(roomId);
    stats.messagesExchanged++;
    stats.lastActivity = new Date();
    
    // Estimar a largura de banda utilizada
    if (messageSize > 0) {
        // Média móvel da largura de banda
        stats.bandwidth = stats.bandwidth * 0.7 + messageSize * 0.3;
    }
};

/**
 * Analisa a qualidade da oferta SDP para logging
 * @param {string} sdp - String SDP
 * @returns {object} - Informações sobre a qualidade
 */
const analyzeSdpQuality = (sdp) => {
    const result = {
        hasVideo: sdp.includes('m=video'),
        hasAudio: sdp.includes('m=audio'),
        hasH264: sdp.includes('H264'),
        hasVP8: sdp.includes('VP8'),
        hasVP9: sdp.includes('VP9'),
        resolution: "unknown",
        fps: "unknown"
    };
    
    // Tentar extrair resolução
    const resMatch = sdp.match(/a=imageattr:[0-9]+ send \[x=([0-9]+)\,y=([0-9]+)\]/);
    if (resMatch && resMatch.length >= 3) {
        result.resolution = `${resMatch[1]}x${resMatch[2]}`;
    }
    
    // Tentar extrair FPS
    const fpsMatch = sdp.match(/a=framerate:([0-9]+)/);
    if (fpsMatch && fpsMatch.length >= 2) {
        result.fps = `${fpsMatch[1]}fps`;
    }
    
    return result;
};

// Manipular conexões WebSocket
wss.on('connection', (ws) => {
    log('Nova conexão estabelecida via WebSocket');
    
    // Identificar cliente
    const clientId = uuidv4();
    ws.id = clientId;
    ws.isAlive = true;
    clients.set(clientId, ws);
    
    let roomId = null;
    
    // Ping para manter conexão viva - intervalo reduzido para rede local
    ws.on('pong', () => {
        ws.isAlive = true;
    });
    
    // Tratamento de erros específico
    ws.on('error', (error) => {
        log(`Erro WebSocket para cliente ${ws.id}: ${error.message}`);
    });
    
    // Processar mensagens
    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            
            // Obter roomId da mensagem ou usar padrão
            const msgRoomId = data.roomId || 'ios-camera';
            
            if (data.type === 'join') {
                roomId = data.roomId || 'ios-camera';
                
                // Garantir que a sala exista
                if (!rooms[roomId]) {
                    rooms[roomId] = [];
                    roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
                    log(`Nova sala criada: ${roomId}`);
                }
                
                // Limitar número de conexões por sala
                if (rooms[roomId].length >= MAX_CONNECTIONS) {
                    ws.send(JSON.stringify({
                        type: 'error',
                        message: 'Room is full, maximum 2 connections allowed'
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
                    const quality = analyzeSdpQuality(data.sdp);
                    log(`Qualidade da oferta: video=${quality.hasVideo}, audio=${quality.hasAudio}, codec=${quality.hasH264 ? 'H264' : (quality.hasVP9 ? 'VP9' : (quality.hasVP8 ? 'VP8' : 'unknown'))}, resolução=${quality.resolution}, fps=${quality.fps}`, true);
                    
                    // Atualizar estatísticas da sala
                    const stats = getRoomStats(roomId);
                    stats.resolution = quality.resolution;
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
                
                updateRoomActivity(roomId, message.length);
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
                
                updateRoomActivity(roomId, message.length);
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
                
                updateRoomActivity(roomId, message.length);
            } 
            // Processar bye (desconexão)
            else if (data.type === 'bye' && roomId) {
                log(`Mensagem 'bye' recebida de ${ws.id}`);
                
                // Notificar outros clientes sobre desconexão
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({
                            type: 'peer-disconnected',
                            userId: ws.id
                        }));
                    }
                });
                
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
                
                updateRoomActivity(roomId, message.length);
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
        
        clients.delete(clientId);
        
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
// Intervalo reduzido para 5 segundos para detecção rápida de desconexões
const pingInterval = setInterval(() => {
    wss.clients.forEach(ws => {
        if (ws.isAlive === false) {
            log(`Terminando conexão inativa com ${ws.id}`);
            return ws.terminate();
        }
        
        ws.isAlive = false;
        ws.ping(() => {});
    });
}, KEEP_ALIVE_INTERVAL);

// Limpar intervalo quando o servidor é fechado
wss.on('close', () => {
    clearInterval(pingInterval);
});

// Rota padrão para o cliente WebRTC
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// Informações sobre o servidor
app.get('/info', (req, res) => {
    // Preparar estatísticas de salas
    const roomsInfo = {};
    Object.keys(roomStats).forEach(roomId => {
        const stats = roomStats[roomId];
        roomsInfo[roomId] = {
            connections: stats.connections,
            messagesExchanged: stats.messagesExchanged,
            resolution: stats.resolution,
            created: stats.created,
            lastActivity: stats.lastActivity
        };
    });
    
    res.json({
        clients: wss.clients.size,
        rooms: Object.keys(rooms).length,
        roomsInfo: roomsInfo,
        uptime: process.uptime()
    });
});

// Obter informações sobre uma sala específica
app.get('/room/:roomId/info', (req, res) => {
    const roomId = req.params.roomId;
    
    if (!rooms[roomId]) {
        return res.status(404).json({ error: 'Sala não encontrada' });
    }
    
    const stats = getRoomStats(roomId);
    
    res.json({
        id: roomId,
        clients: rooms[roomId].length,
        connections: stats.connections,
        messagesExchanged: stats.messagesExchanged,
        resolution: stats.resolution,
        created: stats.created,
        lastActivity: stats.lastActivity
    });
});

// Função para obter endereços IP locais disponíveis
function getLocalIPs() {
    const interfaces = os.networkInterfaces();
    const addresses = [];
    
    Object.keys(interfaces).forEach(interfaceName => {
        interfaces[interfaceName].forEach(iface => {
            // Ignorar endereços IPv6 e loopback
            if (iface.family === 'IPv4' && !iface.internal) {
                addresses.push(iface.address);
            }
        });
    });
    
    return addresses;
}

// Iniciar servidor
server.listen(PORT, () => {
    const addresses = getLocalIPs();
    
    log(`Servidor WebRTC rodando na porta ${PORT}`);
    log(`Interfaces de rede disponíveis: ${addresses.join(', ')}`);
    log(`Interface web disponível em http://localhost:${PORT}`);
    log(`Use um dos seguintes endereços para conexão externa:`);
    addresses.forEach(addr => {
        log(`  http://${addr}:${PORT}`);
    });
});