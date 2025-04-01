/**
 * Servidor WebRTC Simplificado para iOS (Apenas Console)
 * 
 * Este servidor é otimizado para transmitir vídeo para dispositivos iOS com
 * máxima compatibilidade e desempenho. Funciona apenas via console, sem interface web.
 */

const http = require('http');
const WebSocket = require('ws');
const { exec } = require('child_process');
const readline = require('readline');
const os = require('os');

// Configurações
const PORT = process.env.PORT || 8080;
const DEFAULT_ROOM_ID = 'ios-camera'; // Sala padrão para conexão

// Configurações otimizadas para iOS baseadas nos logs de diagnóstico
const IOS_OPTIMIZED_CONFIG = {
    // Formatos de pixel preferidos pelo iOS (em ordem)
    pixelFormats: ['420f', '420v', 'BGRA'],
    
    // Configurações de vídeo em ordem de preferência (baseadas nos logs de diagnóstico)
    videoPresets: [
        {name: 'ultra', width: 4032, height: 3024, fps: 30, bitrate: 12000},      // Câmera traseira foto/alta qualidade
        {name: 'front-ultra', width: 3088, height: 2320, fps: 30, bitrate: 10000}, // Câmera frontal foto/alta qualidade
        {name: '1080p', width: 1920, height: 1080, fps: 60, bitrate: 8000},        // Full HD com 60fps
        {name: 'front-hd', width: 1440, height: 1080, fps: 60, bitrate: 6000},     // Específico para câmera frontal
        {name: '720p', width: 1280, height: 720, fps: 60, bitrate: 4000},          // HD com 60fps
        {name: '480p', width: 854, height: 480, fps: 30, bitrate: 2000}            // SD
    ],
    
    // Parâmetros H264 preferidos para iOS
    h264: {
        profiles: ['42e01f', '42001f'], // Perfis compatíveis com iOS
        level: '1f',
        packetizationMode: 1
    },
    
    // Parâmetros de adaptação de taxa
    adaptiveRate: {
        initial_bitrate: 12000, // kbps
        min_bitrate: 2000,      // kbps
        max_bitrate: 15000      // kbps
    }
};

// Inicializar servidor HTTP mínimo
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Servidor WebRTC rodando. Controle via console.');
});

const wss = new WebSocket.Server({ server });

// Armazenamento de estado
const rooms = {};
const clients = new Map();
const webcams = [];
let selectedWebcam = null;
let isTransmitting = false;

// Interface de linha de comando
const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

// Função para log
function log(message) {
    const now = new Date();
    const timestamp = `[${now.toISOString()}]`;
    console.log(`${timestamp} ${message}`);
}

// Detectar webcams disponíveis
function detectWebcams() {
    return new Promise((resolve, reject) => {
        // Comando diferente para cada sistema operacional
        let command = '';
        
        if (process.platform === 'darwin') { // macOS
            command = 'system_profiler SPCameraDataType | grep "^    " | awk -F": " \'{print $2}\'';
        } else if (process.platform === 'win32') { // Windows
            command = 'wmic path Win32_PnPEntity where "ConfigManagerErrorCode=0 AND PNPClass=\'Image\'" get Caption';
        } else { // Linux
            command = 'v4l2-ctl --list-devices | grep -v "\t" | grep -v "^$"';
        }
        
        exec(command, (error, stdout, stderr) => {
            if (error) {
                log(`Erro ao detectar webcams: ${error.message}`);
                resolve([]);
                return;
            }
            
            // Processar a saída do comando
            const devices = stdout.trim().split('\n')
                .map(line => line.trim())
                .filter(line => line.length > 0);
            
            // Criar lista formatada de webcams
            const result = devices.map((name, index) => ({
                id: index,
                name: name
            }));
            
            resolve(result);
        });
    });
}

// Iniciar transmissão
function startTransmission() {
    if (!selectedWebcam) {
        log('Erro: Nenhuma webcam selecionada');
        return false;
    }
    
    isTransmitting = true;
    log(`Iniciando transmissão da câmera: ${selectedWebcam.name}`);
    
    // Configurações de stream otimizadas para iOS
    const streamConfig = {
        audio: {
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true
        },
        video: {
            width: { ideal: 1920, max: 4032 },
            height: { ideal: 1080, max: 3024 },
            frameRate: { ideal: 60, min: 30 }
        }
    };
    
    // Notificar todos os clientes conectados
    for (const clientWs of clients.values()) {
        if (clientWs.readyState === WebSocket.OPEN) {
            clientWs.send(JSON.stringify({
                type: 'transmission-started',
                webcam: selectedWebcam.name,
                config: streamConfig
            }));
        }
    }
    
    return true;
}

// Parar transmissão
function stopTransmission() {
    isTransmitting = false;
    log('Transmissão parada');
    
    // Notificar todos os clientes conectados
    for (const clientWs of clients.values()) {
        if (clientWs.readyState === WebSocket.OPEN) {
            clientWs.send(JSON.stringify({
                type: 'transmission-stopped'
            }));
        }
    }
}

// Menu inicial
function startInitialMenu() {
    console.clear();
    console.log('=============================================');
    console.log('   SERVIDOR WEBRTC PARA CÂMERA VIRTUAL iOS   ');
    console.log('=============================================');
    
    log('Detectando webcams...');
    
    detectWebcams().then(devices => {
        webcams.length = 0;
        devices.forEach(device => webcams.push(device));
        
        if (webcams.length === 0) {
            log('Nenhuma webcam detectada!');
            rl.question('Pressione ENTER para tentar novamente ou CTRL+C para sair...', () => {
                startInitialMenu();
            });
            return;
        }
        
        console.log('\nWebcams disponíveis:');
        console.log('---------------------------------------------');
        webcams.forEach(cam => {
            console.log(`${cam.id}. ${cam.name}`);
        });
        console.log('---------------------------------------------');
        
        rl.question('Selecione o número da webcam para transmitir (ou CTRL+C para sair): ', (answer) => {
            const id = parseInt(answer.trim());
            const webcam = webcams.find(cam => cam.id === id);
            
            if (webcam) {
                selectedWebcam = webcam;
                log(`Webcam selecionada: ${webcam.name}`);
                
                startTransmission();
                showOperationalMenu();
            } else {
                log('Seleção inválida!');
                setTimeout(startInitialMenu, 1000);
            }
        });
    });
}

// Menu operacional (após iniciar transmissão)
function showOperationalMenu() {
    console.clear();
    console.log('=============================================');
    console.log('   SERVIDOR WEBRTC PARA CÂMERA VIRTUAL iOS   ');
    console.log('=============================================');
    console.log(`Status: ${isTransmitting ? 'TRANSMITINDO ✅' : 'PARADO ❌'}`);
    console.log(`Webcam: ${selectedWebcam ? selectedWebcam.name : 'Nenhuma'}`);
    console.log(`Clientes conectados: ${clients.size}`);
    console.log('---------------------------------------------');
    console.log('Comandos:');
    console.log('  1. Parar/Iniciar Transmissão');
    console.log('  2. Trocar Webcam');
    console.log('  3. Ver Clientes Conectados');
    console.log('  4. Ver Configurações Atuais');
    console.log('  0. Sair');
    console.log('---------------------------------------------');
    
    rl.question('Digite o número do comando: ', (answer) => {
        switch (answer.trim()) {
            case '1':
                if (isTransmitting) {
                    stopTransmission();
                    log('Transmissão interrompida');
                } else {
                    startTransmission();
                    log('Transmissão iniciada');
                }
                setTimeout(showOperationalMenu, 1000);
                break;
            case '2':
                startInitialMenu();
                break;
            case '3':
                showClientsInfo();
                break;
            case '4':
                showCurrentConfig();
                break;
            case '0':
                log('Encerrando servidor...');
                process.exit(0);
                break;
            default:
                log('Comando inválido');
                setTimeout(showOperationalMenu, 1000);
        }
    });
}

// Mostrar informações dos clientes
function showClientsInfo() {
    console.clear();
    console.log('Clientes Conectados:');
    console.log('---------------------------------------------');
    
    if (clients.size === 0) {
        console.log('Nenhum cliente conectado');
    } else {
        let index = 0;
        for (const [clientId, ws] of clients.entries()) {
            const deviceType = ws.deviceType || 'desconhecido';
            const state = ws.readyState === WebSocket.OPEN ? 'Conectado' : 'Desconectado';
            console.log(`${index + 1}. ID: ${clientId.substring(0, 8)}... | Tipo: ${deviceType} | Estado: ${state}`);
            index++;
        }
    }
    
    console.log('---------------------------------------------');
    rl.question('Pressione ENTER para voltar...', () => {
        showOperationalMenu();
    });
}

// Mostrar configuração atual
function showCurrentConfig() {
    console.clear();
    console.log('Configuração Atual:');
    console.log('---------------------------------------------');
    console.log('Pixel Formats: ' + IOS_OPTIMIZED_CONFIG.pixelFormats.join(', '));
    console.log('Bitrate: ' + IOS_OPTIMIZED_CONFIG.adaptiveRate.initial_bitrate + ' kbps');
    console.log('H.264 Profiles: ' + IOS_OPTIMIZED_CONFIG.h264.profiles.join(', '));
    console.log('Video Presets:');
    
    IOS_OPTIMIZED_CONFIG.videoPresets.forEach(preset => {
        console.log(`  - ${preset.name}: ${preset.width}x${preset.height}, ${preset.fps}fps, ${preset.bitrate}kbps`);
    });
    
    console.log('---------------------------------------------');
    rl.question('Pressione ENTER para voltar...', () => {
        showOperationalMenu();
    });
}

// Manipulador de WebSocket
wss.on('connection', (ws, req) => {
    const clientId = Math.random().toString(36).substring(2, 15);
    ws.id = clientId;
    
    // Detectar tipo de dispositivo
    const userAgent = req.headers['user-agent'] || '';
    if (userAgent.includes('iPhone') || userAgent.includes('iPad') || userAgent.includes('iPod')) {
        ws.deviceType = 'ios';
    } else if (userAgent.includes('Android')) {
        ws.deviceType = 'android';
    } else {
        ws.deviceType = 'desktop';
    }
    
    log(`Nova conexão: ${clientId} (${ws.deviceType})`);
    clients.set(clientId, ws);
    
    // Enviar informações de conexão
    ws.send(JSON.stringify({
        type: 'welcome',
        id: clientId,
        isTransmitting,
        webcam: selectedWebcam ? selectedWebcam.name : null,
        iosConfig: ws.deviceType === 'ios' ? IOS_OPTIMIZED_CONFIG : null
    }));
    
    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            log(`Mensagem recebida de ${clientId}: ${data.type}`);
            
            // Processar diferentes tipos de mensagens
            switch (data.type) {
                case 'join':
                    // Cliente entrando em uma sala
                    const roomId = data.roomId || DEFAULT_ROOM_ID;
                    
                    if (!rooms[roomId]) {
                        rooms[roomId] = new Set();
                    }
                    
                    rooms[roomId].add(ws);
                    ws.roomId = roomId;
                    
                    log(`Cliente ${clientId} entrou na sala: ${roomId}`);
                    
                    // Notificar outros na sala
                    for (const client of rooms[roomId]) {
                        if (client !== ws && client.readyState === WebSocket.OPEN) {
                            client.send(JSON.stringify({
                                type: 'user-joined',
                                userId: clientId,
                                deviceType: ws.deviceType
                            }));
                        }
                    }
                    
                    // Se iOS, enviar capacidades otimizadas
                    if (ws.deviceType === 'ios') {
                        // Broadcast das capacidades do iOS para todos na sala
                        for (const client of rooms[roomId]) {
                            if (client !== ws && client.readyState === WebSocket.OPEN) {
                                client.send(JSON.stringify({
                                    type: 'ios-capabilities-update',
                                    capabilities: IOS_OPTIMIZED_CONFIG
                                }));
                            }
                        }
                    }
                    
                    // Se já estiver transmitindo, enviar configurações atuais
                    if (isTransmitting && selectedWebcam) {
                        ws.send(JSON.stringify({
                            type: 'transmission-active',
                            webcam: selectedWebcam.name,
                            config: {
                                initialBitrate: IOS_OPTIMIZED_CONFIG.adaptiveRate.initial_bitrate,
                                minBitrate: IOS_OPTIMIZED_CONFIG.adaptiveRate.min_bitrate,
                                maxBitrate: IOS_OPTIMIZED_CONFIG.adaptiveRate.max_bitrate
                            }
                        }));
                    }
                    break;
                    
                case 'offer':
                case 'answer':
                case 'ice-candidate':
                    // Reencaminhar mensagens de sinalização WebRTC para a sala
                    const room = rooms[ws.roomId];
                    if (room) {
                        for (const client of room) {
                            if (client !== ws && client.readyState === WebSocket.OPEN) {
                                // Para ofertas, otimizar SDP para o dispositivo de destino
                                if (data.type === 'offer' && client.deviceType === 'ios' && data.sdp) {
                                    // Modificar SDP para otimizar para iOS
                                    data.sdp = optimizeSdpForIOS(data.sdp);
                                }
                                
                                client.send(JSON.stringify(data));
                            }
                        }
                    }
                    break;
                    
                case 'bye':
                    // Cliente saindo da sala
                    handleClientLeave(ws);
                    break;
                    
                case 'ping':
                    // Responder a ping para manter conexão viva
                    ws.send(JSON.stringify({
                        type: 'pong',
                        timestamp: Date.now()
                    }));
                    break;
                    
                case 'stats':
                    // Receber estatísticas de conexão e ajustar parâmetros
                    if (data.stats && data.stats.video) {
                        processConnectionStats(data.stats, ws);
                    }
                    break;
            }
        } catch (e) {
            log(`Erro ao processar mensagem: ${e.message}`);
        }
    });
    
    ws.on('close', () => {
        log(`Conexão fechada: ${clientId}`);
        handleClientLeave(ws);
        clients.delete(clientId);
        
        // Atualizar a tela operacional se estiver ativa
        if (isTransmitting) {
            // Atualizamos apenas o contador na linha de comando
            process.stdout.write(`\rClientes conectados: ${clients.size}`);
        }
    });
    
    ws.on('error', (error) => {
        log(`Erro na conexão ${clientId}: ${error.message}`);
    });
    
    // Se já estiver transmitindo, notificar o novo cliente
    if (isTransmitting && selectedWebcam) {
        ws.send(JSON.stringify({
            type: 'transmission-active',
            webcam: selectedWebcam.name
        }));
    }
    
    // Atualizar a tela operacional se estiver ativa
    if (isTransmitting) {
        // Atualizamos apenas o contador na linha de comando
        process.stdout.write(`\rClientes conectados: ${clients.size}`);
    }
});

// Função para processar estatísticas de conexão e otimizar parâmetros
function processConnectionStats(stats, ws) {
    // Implementação simplificada para ajustar configurações com base nas estatísticas
    if (stats.bandwidth && stats.packetLoss !== undefined) {
        // Armazenar estatísticas para este cliente
        ws.connectionStats = {
            bandwidth: stats.bandwidth, // kbps
            packetLoss: stats.packetLoss, // percentage
            rtt: stats.rtt || 0, // round trip time in ms
            timestamp: Date.now()
        };
        
        // Verificar problemas na conexão
        if (stats.packetLoss > 5) { // mais de 5% de perda de pacotes
            // Enviar recomendação para reduzir qualidade
            if (ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({
                    type: 'quality-recommendation',
                    action: 'decrease-bitrate',
                    targetBitrate: Math.max(
                        stats.bandwidth * 0.7, // 70% da largura de banda atual
                        IOS_OPTIMIZED_CONFIG.adaptiveRate.min_bitrate // não cair abaixo do mínimo
                    )
                }));
            }
        } 
        else if (stats.packetLoss < 1 && stats.bandwidth > IOS_OPTIMIZED_CONFIG.adaptiveRate.initial_bitrate * 1.2) {
            // Conexão boa, pode aumentar a qualidade
            if (ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({
                    type: 'quality-recommendation',
                    action: 'increase-bitrate',
                    targetBitrate: Math.min(
                        stats.bandwidth * 1.2, // 120% da largura de banda atual
                        IOS_OPTIMIZED_CONFIG.adaptiveRate.max_bitrate // não exceder o máximo
                    )
                }));
            }
        }
    }
}

// Função para lidar com cliente que sai
function handleClientLeave(ws) {
    const roomId = ws.roomId;
    if (roomId && rooms[roomId]) {
        rooms[roomId].delete(ws);
        
        // Notificar outros na sala
        for (const client of rooms[roomId]) {
            if (client.readyState === WebSocket.OPEN) {
                client.send(JSON.stringify({
                    type: 'user-left',
                    userId: ws.id
                }));
            }
        }
        
        // Se sala vazia, remover
        if (rooms[roomId].size === 0) {
            delete rooms[roomId];
        }
    }
}

// Otimização SDP para iOS (baseado nos logs de diagnóstico)
function optimizeSdpForIOS(sdp) {
    const lines = sdp.split('\n');
    let inVideoSection = false;
    let videoSectionModified = false;
    let h264PayloadType = null;
    const newLines = [];
    
    // Encontrar payload type para H264
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.includes('a=rtpmap:') && line.includes('H264')) {
            h264PayloadType = line.split(':')[1].split(' ')[0];
            break;
        }
    }
    
    // Modificar o SDP para otimização iOS
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        
        // Detectar seção de vídeo
        if (line.startsWith('m=video')) {
            inVideoSection = true;
            
            // Reordenar codecs para priorizar H264 se disponível
            if (h264PayloadType) {
                const parts = line.split(' ');
                const payloadTypes = parts.slice(3);
                const index = payloadTypes.indexOf(h264PayloadType);
                
                if (index !== -1) {
                    payloadTypes.splice(index, 1);
                    const newPayloadTypes = [h264PayloadType, ...payloadTypes];
                    newLines.push(`${parts[0]} ${parts[1]} ${parts[2]} ${newPayloadTypes.join(' ')}`);
                    continue;
                }
            }
        } else if (line.startsWith('m=')) {
            inVideoSection = false;
        }
        
        // Adicionar bitrate para vídeo após a linha 'c='
        if (inVideoSection && line.startsWith('c=') && !videoSectionModified) {
            newLines.push(line);
            
            // Verificar se já existe uma linha b=AS
            let hasAS = false;
            for (let j = i + 1; j < lines.length && !lines[j].startsWith('m='); j++) {
                if (lines[j].startsWith('b=AS:')) {
                    hasAS = true;
                    break;
                }
            }
            
            // Adicionar linha de bitrate se não existir
            if (!hasAS) {
                newLines.push(`b=AS:${IOS_OPTIMIZED_CONFIG.adaptiveRate.initial_bitrate}`); // Usar valor configurado
                newLines.push(`b=TIAS:${IOS_OPTIMIZED_CONFIG.adaptiveRate.initial_bitrate * 1000}`);
                videoSectionModified = true;
            }
            continue;
        }
        
        // Otimizar perfil H264 para iOS
        if (inVideoSection && line.startsWith('a=fmtp:') && h264PayloadType && 
            line.includes(h264PayloadType)) {
            
            // Perfil preferido para iOS
            if (!line.includes('profile-level-id=')) {
                // Adicionar perfil compatível com iOS
                newLines.push(`${line};profile-level-id=42e01f`);
                continue;
            } else if (!line.includes('profile-level-id=42e01f') && 
                     !line.includes('profile-level-id=42001f')) {
                // Substituir perfil existente por um compatível com iOS
                const newLine = line.replace(
                    /profile-level-id=[0-9a-fA-F]+/,
                    'profile-level-id=42e01f'
                );
                newLines.push(newLine);
                continue;
            }
            
            // Garantir packetization-mode=1 para iOS
            if (!line.includes('packetization-mode=')) {
                newLines.push(`${line};packetization-mode=1`);
                continue;
            }
            
            // Garantir que max-fr (max frame rate) esteja presente
            if (!line.includes('max-fr=')) {
                const newLine = line.includes(';') ? 
                    `${line};max-fr=60` : 
                    `${line};max-fr=60`;
                newLines.push(newLine);
                continue;
            }
        }
        
        // Configurar NACK para melhor recuperação de pacotes perdidos
        if (inVideoSection && line.startsWith('a=rtcp-fb:') && 
            line.includes(h264PayloadType) && !line.includes('nack')) {
            newLines.push(line);
            newLines.push(`a=rtcp-fb:${h264PayloadType} nack`);
            newLines.push(`a=rtcp-fb:${h264PayloadType} nack pli`);
            continue;
        }
        
        newLines.push(line);
    }
    
    return newLines.join('\n');
}

// Função para obter endereços IP locais
function getLocalIPs() {
    const interfaces = os.networkInterfaces();
    const addresses = [];
    
    Object.keys(interfaces).forEach((interfaceName) => {
        interfaces[interfaceName].forEach((iface) => {
            // Ignorar endereços IPv6 e loopback
            if (iface.family === 'IPv4' && !iface.internal) {
                addresses.push(iface.address);
            }
        });
    });
    
    return addresses;
}

// Iniciar o servidor
server.listen(PORT, async () => {
    const addresses = getLocalIPs();
    console.clear();
    
    console.log('=============================================');
    console.log('   SERVIDOR WEBRTC PARA CÂMERA VIRTUAL iOS   ');
    console.log('=============================================');
    console.log(`Servidor iniciado na porta ${PORT}`);
    console.log('Endereços para conexão:');
    addresses.forEach(addr => {
        console.log(`  - ws://${addr}:${PORT}`);
    });
    console.log('=============================================');
    
    // Iniciar interface de linha de comando
    setTimeout(startInitialMenu, 1000);
});

// Manipular encerramento limpo
function shutdown() {
    log('Encerrando servidor...');
    
    // Notificar todos os clientes
    for (const ws of clients.values()) {
        if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({
                type: 'server-shutdown'
            }));
            ws.terminate();
        }
    }
    
    // Fechar servidor HTTP
    server.close(() => {
        log('Servidor encerrado com sucesso');
        process.exit(0);
    });
    
    // Forçar encerramento após 3 segundos se não fechar normalmente
    setTimeout(() => {
        log('Forçando encerramento...');
        process.exit(1);
    }, 3000);
}

// Manipular sinais de encerramento
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
