// Elementos da página
const startButton = document.getElementById('startButton');
const stopButton = document.getElementById('stopButton');
const videoSource = document.getElementById('videoSource');
const videoQuality = document.getElementById('videoQuality');
const frameRate = document.getElementById('frameRate');
const localVideo = document.getElementById('localVideo');
const roomIdInput = document.getElementById('roomId');
const statusDiv = document.getElementById('status');
const videoStats = document.getElementById('videoStats');
const connectionStats = document.getElementById('connectionStats');
const statsPanel = document.getElementById('statsPanel');
const advancedToggle = document.getElementById('advancedToggle');
const advancedSection = document.getElementById('advancedSection');
const videoCodec = document.getElementById('videoCodec');
const h264Profile = document.getElementById('h264Profile');
const pixelFormat = document.getElementById('pixelFormat');
const iosOptimize = document.getElementById('iosOptimize');
const connectionInfo = document.getElementById('connectionInfo');

// Toggle para configurações avançadas
advancedToggle.addEventListener('click', () => {
    advancedSection.classList.toggle('hidden');
    advancedToggle.querySelector('span:last-child').textContent = 
        advancedSection.classList.contains('hidden') ? '▼' : '▲';
});

// Variáveis WebRTC
let localStream;
let peerConnection;
let ws;
let statsInterval;
let reconnectTimeout;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 5;
const serverUrl = location.hostname === 'localhost' || location.hostname === '127.0.0.1'
    ? `ws://${location.host}`
    : `ws://${location.hostname}:8080`;

// Para controle de keep-alive
let keepAliveInterval;
let lastPongReceived = 0;
let connectionCheckInterval;
let offerCreatedForRoom = {};

// Mapeamento de qualidades de vídeo
const videoQualities = {
    '720p': { width: 1280, height: 720 },
    '1080p': { width: 1920, height: 1080 },
    '1440p': { width: 2560, height: 1440 },
    '2160p': { width: 3840, height: 2160 }
};

// Inicialização
async function initialize() {
    try {
        updateStatus('Inicializando câmeras...', 'connecting');

        // Verificar suporte a getUserMedia
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            throw new Error('Seu navegador não suporta acesso à câmera (getUserMedia)');
        }

        // Listar dispositivos de vídeo disponíveis
        const devices = await navigator.mediaDevices.enumerateDevices();
        const videoDevices = devices.filter(device => device.kind === 'videoinput');

        // Adicionar opções ao select
        videoSource.innerHTML = '';
        videoDevices.forEach(device => {
            const option = document.createElement('option');
            option.value = device.deviceId;
            option.text = device.label || `Câmera ${videoSource.length + 1}`;
            videoSource.appendChild(option);
        });

        // Se não houver rótulos, solicitar permissão de câmera e retornar
        if (videoDevices.length > 0 && !videoDevices[0].label) {
            try {
                // Solicitar permissão e mostrar preview inicial
                await getLocalMediaStream();
                
                // Atualizar lista de dispositivos com os rótulos
                const updatedDevices = await navigator.mediaDevices.enumerateDevices();
                const updatedVideoDevices = updatedDevices.filter(device => device.kind === 'videoinput');
                
                // Limpar e repopular o select
                videoSource.innerHTML = '';
                updatedVideoDevices.forEach(device => {
                    const option = document.createElement('option');
                    option.value = device.deviceId;
                    option.text = device.label || `Câmera ${videoSource.length + 1}`;
                    videoSource.appendChild(option);
                });
                
                // Configurar a câmera preferencial
                const preferredCameras = updatedVideoDevices.filter(device =>
                    device.label.toLowerCase().includes('hd') ||
                    device.label.toLowerCase().includes('4k') ||
                    device.label.toLowerCase().includes('pro')
                );

                if (preferredCameras.length > 0) {
                    videoSource.value = preferredCameras[0].deviceId;
                }
                
                updateStatus('Pronto para transmitir', 'offline');
            } catch (err) {
                console.error('Erro ao acessar câmera durante inicialização:', err);
                updateStatus('Erro ao acessar câmera', 'offline');
            }
            return;
        }

        if (videoDevices.length === 0) {
            updateStatus('Nenhuma câmera encontrada', 'offline');
        } else {
            updateStatus('Pronto para transmitir', 'offline');
            
            // Configurar câmera preferencial
            const preferredCameras = videoDevices.filter(device =>
                device.label.toLowerCase().includes('hd') ||
                device.label.toLowerCase().includes('4k') ||
                device.label.toLowerCase().includes('pro')
            );

            if (preferredCameras.length > 0) {
                videoSource.value = preferredCameras[0].deviceId;
            }
        }
    } catch (error) {
        console.error('Erro ao inicializar:', error);
        updateStatus(`Erro: ${error.message}`, 'offline');
    }
    
    // Iniciar verificação de saúde da conexão
    startConnectionHealthCheck();
}

// Obter stream local com qualidade configurada
async function getLocalMediaStream() {
    try {
        if (localStream) {
            localStream.getTracks().forEach(track => track.stop());
        }

        // Obter qualidade selecionada
        const quality = videoQualities[videoQuality.value];
        const fps = parseInt(frameRate.value);

        console.log(`Configurando vídeo: ${quality.width}x${quality.height} a ${fps}fps`);

        const constraints = {
            audio: false,
            video: {
                deviceId: videoSource.value ? { exact: videoSource.value } : undefined,
                width: { ideal: quality.width },
                height: { ideal: quality.height },
                frameRate: { ideal: fps }
            }
        };

        localStream = await navigator.mediaDevices.getUserMedia(constraints);

        // Log das configurações reais obtidas
        const videoTrack = localStream.getVideoTracks()[0];
        if (videoTrack) {
            const settings = videoTrack.getSettings();
            console.log('Configurações reais do vídeo:', settings);
            videoStats.innerHTML = `Fonte: ${videoTrack.label}<br>` +
                                `Resolução: ${settings.width}x${settings.height}<br>` +
                                `FPS: ${settings.frameRate || 'desconhecido'}<br>` +
                                `Aspect Ratio: ${(settings.width/settings.height).toFixed(2)}`;
            statsPanel.classList.remove('hidden');
        }

        localVideo.srcObject = localStream;
        return localStream;
    } catch (error) {
        console.error('Erro ao acessar câmera:', error);
        updateStatus(`Erro ao acessar câmera: ${error.message}`, 'offline');
        throw error;
    }
}

// Configurar conexão WebRTC
function setupPeerConnection() {
    const config = {
        iceServers: [
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' },
        ],
        iceTransportPolicy: 'all',
        bundlePolicy: 'max-bundle',
        rtcpMuxPolicy: 'require',
        sdpSemantics: 'unified-plan',
        // Otimizações para redes locais
        iceCandidatePoolSize: 0
    };

    peerConnection = new RTCPeerConnection(config);

    // Adicionar stream de vídeo
    localStream.getTracks().forEach(track => {
        console.log(`Adicionando track: ${track.kind}`);
        peerConnection.addTrack(track, localStream);
    });

    // Configurar eventos
    peerConnection.onicecandidate = event => {
        if (event.candidate) {
            sendMessage({
                type: 'ice-candidate',
                candidate: event.candidate.candidate,
                sdpMid: event.candidate.sdpMid,
                sdpMLineIndex: event.candidate.sdpMLineIndex,
                roomId: roomIdInput.value
            });
        } else {
            console.log("Coleta de candidatos ICE completa");
        }
    };

    peerConnection.oniceconnectionstatechange = () => {
        console.log('ICE State:', peerConnection.iceConnectionState);
        connectionStats.innerHTML = `ICE State: ${peerConnection.iceConnectionState}`;
        connectionInfo.textContent = `Status da conexão: ${peerConnection.iceConnectionState}`;
        
        // Adicionar log detalhado
        if (peerConnection.iceConnectionState === 'failed' ||
            peerConnection.iceConnectionState === 'disconnected') {
            console.error('Problema na conexão ICE:', peerConnection.iceConnectionState);
        } else if (peerConnection.iceConnectionState === 'disconnected' ||
                  peerConnection.iceConnectionState === 'failed' ||
                  peerConnection.iceConnectionState === 'closed') {
            updateStatus('Dispositivo desconectado', 'offline');
        }
    };

    // Monitor de estatísticas
    startStatsMonitor();
}

// Iniciar monitoramento de estatísticas
function startStatsMonitor() {
    if (statsInterval) {
        clearInterval(statsInterval);
    }

    statsInterval = setInterval(async () => {
        if (!peerConnection) return;

        const stats = await peerConnection.getStats();
        let outboundRtpStats;

        stats.forEach(stat => {
            if (stat.type === 'outbound-rtp' && stat.kind === 'video') {
                outboundRtpStats = stat;
            }
        });

        if (outboundRtpStats) {
            const { bytesSent, packetsSent, framesSent, framesPerSecond } = outboundRtpStats;

            connectionStats.innerHTML = `ICE State: ${peerConnection.iceConnectionState}<br>` +
                                   `Dados enviados: ${formatBytes(bytesSent)}<br>` +
                                   `Pacotes enviados: ${packetsSent}<br>` +
                                   `Frames enviados: ${framesSent}<br>` +
                                   `FPS atual: ${framesPerSecond || 'desconhecido'}`;
        }
    }, 1000);
}

// Formatar bytes para exibição
function formatBytes(bytes, decimals = 2) {
    if (bytes === 0) return '0 Bytes';

    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));

    return parseFloat((bytes / Math.pow(k, i)).toFixed(decimals)) + ' ' + sizes[i];
}

// Iniciar keep-alive timer
function startKeepAliveTimer() {
    // Limpar intervalo existente, se houver
    if (keepAliveInterval) {
        clearInterval(keepAliveInterval);
    }
    
    // Enviar ping a cada 10 segundos
    keepAliveInterval = setInterval(() => {
        if (ws && ws.readyState === WebSocket.OPEN) {
            sendMessage({
                type: 'ping',
                timestamp: Date.now(),
                roomId: roomIdInput.value
            });
            console.log("Enviando keep-alive ping para o servidor");
        }
    }, 10000); // A cada 10 segundos
}

// Parar keep-alive timer
function stopKeepAliveTimer() {
    if (keepAliveInterval) {
        clearInterval(keepAliveInterval);
        keepAliveInterval = null;
    }
}

// Verificar saúde da conexão periodicamente
function startConnectionHealthCheck() {
    if (connectionCheckInterval) {
        clearInterval(connectionCheckInterval);
    }
    
    // Verificar a cada 15 segundos se recebemos pong recentemente
    connectionCheckInterval = setInterval(() => {
        if (ws && ws.readyState === WebSocket.OPEN && startButton.disabled) {
            const now = Date.now();
            // Se não recebemos pong há mais de 30 segundos, a conexão pode estar "zumbi"
            if (lastPongReceived > 0 && now - lastPongReceived > 30000) {
                console.warn("Possível conexão zumbi detectada - sem resposta por 30s");
                updateStatus('Reconectando (conexão inativa)...', 'connecting');
                
                // Forçar reconexão
                ws.close();
                // Reconectar imediatamente
                setTimeout(() => {
                    if (startButton.disabled) {
                        connectWebSocket();
                    }
                }, 1000);
            }
        }
    }, 15000);
}

// Adicione esta função no arquivo main.js
function resetVideoStream() {
    console.log("Resetando stream de vídeo após reconexão");
    
    // Se temos um peerConnection ativo, primeiro limpamos a conexão atual
    if (peerConnection) {
        // Remover a track existente do peerConnection
        const senders = peerConnection.getSenders();
        senders.forEach(sender => {
            peerConnection.removeTrack(sender);
        });
        
        // Fechar conexão peer para liberar recursos
        peerConnection.close();
        peerConnection = null;
    }
    
    // Reconstruir a conexão peer
    setupPeerConnection();
    
    // Não precisamos recriar o stream local, pois ele já existe
    // Mas precisamos readicionar as tracks ao novo peerConnection
    if (localStream) {
        localStream.getTracks().forEach(track => {
            console.log(`Readicionando track: ${track.kind}`);
            peerConnection.addTrack(track, localStream);
        });
    }
    
    connectionInfo.textContent = 'Status da conexão: Reconectado, aguardando dispositivos';
}

// Conectar ao servidor WebSocket com reconexão automática
function connectWebSocket() {
    if (ws && ws.readyState !== WebSocket.CLOSED && ws.readyState !== WebSocket.CLOSING) {
        console.log('WebSocket já está conectado ou conectando');
        return;
    }

    console.log(`Conectando ao WebSocket: ${serverUrl}`);
    
    ws = new WebSocket(serverUrl);

    ws.onopen = () => {
		console.log('WebSocket conectado');
		// Resetar contador de reconexão quando conectado com sucesso
		reconnectAttempts = 0;
		lastPongReceived = Date.now(); // Inicializar timestamp de pong
		
		// Se já estávamos conectados antes (reconexão), resetar o stream de vídeo
		if (reconnectAttempts > 0) {
			// Reset do stream após reconexão para evitar congelamento
			resetVideoStream();
		}
		
		// Enviar informações sobre o tipo de dispositivo e otimizações
		const deviceInfo = {
			type: 'join',
			roomId: roomIdInput.value,
			deviceType: 'web',
			capabilities: {
				h264Supported: true,
				preferIOS: iosOptimize.checked,
				preferredCodec: videoCodec.value,
				preferredH264Profile: h264Profile.value,
				preferredPixelFormat: pixelFormat.value
			}
		};
		
		ws.send(JSON.stringify(deviceInfo));
		updateStatus('Conectado ao servidor', 'online');
		
		// Iniciar keep-alive
		startKeepAliveTimer();
	};

    ws.onclose = (event) => {
        console.log(`WebSocket desconectado (código: ${event.code}, razão: ${event.reason})`);
        updateStatus('Desconectado do servidor', 'offline');
        
        // Parar o keep-alive quando desconectado
        stopKeepAliveTimer();

        // Tentar reconectar após um delay, a menos que a transmissão tenha sido explicitamente parada
        if (startButton.disabled && !stopButton.disabled) {
            const delay = Math.min(1000 * Math.pow(1.5, reconnectAttempts), 10000); // Backoff exponencial com máximo de 10s
            console.log(`Tentando reconectar em ${delay/1000}s (tentativa ${reconnectAttempts + 1}/${MAX_RECONNECT_ATTEMPTS})`);
            
            if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
                reconnectAttempts++;
                updateStatus(`Reconectando em ${Math.round(delay/1000)}s... (${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})`, 'connecting');
                
                clearTimeout(reconnectTimeout);
                reconnectTimeout = setTimeout(() => {
                    connectWebSocket();
                }, delay);
            } else {
                updateStatus('Falha ao reconectar. Tente novamente manualmente.', 'offline');
                // Resetar a interface para permitir nova tentativa
                stopStreaming(false);
            }
        }
    };

    ws.onerror = (error) => {
        console.error('WebSocket erro:', error);
        updateStatus('Erro de conexão', 'offline');
        connectionInfo.textContent = 'Status da conexão: Erro';
    };

    ws.onmessage = (event) => {
        const message = JSON.parse(event.data);
        handleMessage(message);
    };
}

// Enviar mensagem para o servidor
function sendMessage(message) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(message));
    } else {
        console.warn('Não foi possível enviar mensagem, WebSocket não está conectado');
        connectionInfo.textContent = 'Status da conexão: Não conectado';
    }
}

// Processar mensagens recebidas
async function handleMessage(message) {
    console.log('Mensagem recebida:', message.type);

    switch (message.type) {
        case 'user-joined':
			console.log('Dispositivo conectado:', message.deviceType || 'desconhecido');
			
			// Criar oferta apenas se ainda não tivermos criado uma para esta sala,
			// se for um dispositivo iOS, ou após reconexão (para restaurar o streaming)
			const roomId = roomIdInput.value;
			const isIOS = message.deviceType === 'ios';
			
			// Verificar se este é um evento de reconexão do dispositivo iOS
			const isReconnection = reconnectAttempts > 0 || offerCreatedForRoom[roomId];
			
			if (!offerCreatedForRoom[roomId] || isIOS || isReconnection) {
				console.log(`${isIOS ? 'Dispositivo iOS detectado' : (isReconnection ? 'Reconexão detectada' : 'Novo dispositivo')} na sala, criando oferta`);
				// Pequeno atraso para garantir que o peerConnection esteja pronto
				setTimeout(async () => {
					await createAndSendOffer(isIOS); // true para priorizar compatibilidade iOS
					offerCreatedForRoom[roomId] = true;
				}, 500);
			} else {
				console.log('Já existe oferta ativa para esta sala, ignorando');
			}
			break;
            
        case 'answer':
            // Recebendo resposta do dispositivo
            try {
                await peerConnection.setRemoteDescription(new RTCSessionDescription({
                    type: 'answer',
                    sdp: message.sdp
                }));
                
                console.log('Resposta SDP definida com sucesso');
                connectionInfo.textContent = 'Status da conexão: Resposta recebida';
                
                // Se a resposta veio de um dispositivo iOS, registrar isso
                if (message.senderDeviceType === 'ios') {
                    console.log('Resposta recebida de dispositivo iOS');
                    // Ativar automaticamente a opção de otimização para iOS
                    iosOptimize.checked = true;
                }
            } catch (e) {
                console.error('Erro ao definir a resposta SDP:', e);
                connectionInfo.textContent = 'Status da conexão: Erro ao processar resposta';
            }
            break;
            
        case 'ice-candidate':
            // Recebendo candidato ICE
            if (peerConnection) {
                try {
                    await peerConnection.addIceCandidate(new RTCIceCandidate({
                        candidate: message.candidate,
                        sdpMid: message.sdpMid,
                        sdpMLineIndex: message.sdpMLineIndex
                    }));
                } catch (e) {
                    console.error('Erro ao adicionar candidato ICE:', e);
                }
            }
            break;
            
        case 'error':
            console.error('Erro recebido do servidor:', message.message);
            updateStatus(`Erro: ${message.message}`, 'offline');
            connectionInfo.textContent = `Status da conexão: Erro - ${message.message}`;
            break;
            
        case 'ping':
            // Responder imediatamente com pong para manter a conexão viva
            sendMessage({
                type: 'pong',
                timestamp: Date.now(),
                roomId: roomIdInput.value
            });
            break;
            
        case 'pong':
            // Receber pong do servidor (manter conexão viva)
            lastPongReceived = Date.now();
            break;
            
        case 'room-info':
            console.log('Informações da sala:', message);
            
            // Verificar se há dispositivos iOS na sala
            if (message.deviceTypes && message.deviceTypes.includes('ios')) {
                console.log('Dispositivo iOS presente na sala, ativando otimizações');
                iosOptimize.checked = true;
            }
            
            updateStatus(`Conectado (${message.clients} ${message.clients === 1 ? 'usuário' : 'usuários'})`, 'online');
            connectionInfo.textContent = `Status da conexão: Na sala com ${message.clients} ${message.clients === 1 ? 'usuário' : 'usuários'}`;
            break;
            
        case 'ios-capabilities-update':
            // Receber informações sobre as capacidades do dispositivo iOS
            console.log('Atualizando para compatibilidade com dispositivo iOS:', message.capabilities);
            
            // Se recebemos informações específicas de um dispositivo iOS, ajustar configurações
            if (message.capabilities) {
                const caps = message.capabilities;
                
                // Ajustar perfil H264 se especificado
                if (caps.h264Profile) {
                    console.log(`Ajustando para perfil H264 específico do iOS: ${caps.h264Profile}`);
                    if (Array.from(h264Profile.options).some(opt => opt.value === caps.h264Profile)) {
                        h264Profile.value = caps.h264Profile;
                    }
                }
                
                // Ajustar formato de pixels se especificado
                if (caps.pixelFormat) {
                    console.log(`Ajustando para formato de pixel específico do iOS: ${caps.pixelFormat}`);
                    if (Array.from(pixelFormat.options).some(opt => opt.value === caps.pixelFormat)) {
                        pixelFormat.value = caps.pixelFormat;
                    }
                }
            }
            break;
            
        case 'peer-disconnected':
            console.log('Peer desconectado:', message.userId);
            connectionInfo.textContent = 'Status da conexão: Peer desconectado';
            break;
    }
}

// Criar e enviar oferta WebRTC
async function createAndSendOffer(optimizeForIOS = false) {
    try {
        // Configurar para alta qualidade de vídeo
        const offerOptions = {
            offerToReceiveAudio: false,
            offerToReceiveVideo: false
        };

        const offer = await peerConnection.createOffer(offerOptions);

        // Definir preferências para SDP baseado nas configurações
        let sdp = offer.sdp;
        
        // Obter bitrate apropriado baseado na qualidade selecionada
        let bitrate = 5000; // Padrão 5Mbps
        switch(videoQuality.value) {
            case '2160p': bitrate = 12000; break; // 12Mbps para 4K
            case '1440p': bitrate = 8000; break;  // 8Mbps para 1440p
            case '1080p': bitrate = 5000; break;  // 5Mbps para 1080p
            case '720p': bitrate = 2500; break;   // 2.5Mbps para 720p
        }
        
        // Aplicar modificações SDP com base nas configurações
        sdp = setMediaBitrate(sdp, 'video', bitrate);
        
        // Se otimização para iOS está ativada, aplicar otimizações específicas
        if (optimizeForIOS || iosOptimize.checked) {
            console.log('Aplicando otimizações para compatibilidade com iOS');
            
            // 1. Adicionar linha para formato de pixel preferido, se não existir
            const selectedFormat = pixelFormat.value;
            if (selectedFormat && !sdp.includes(selectedFormat)) {
                sdp = addPixelFormatPreference(sdp, selectedFormat);
            }
            
            // 2. Aplicar perfil H264 preferido, se H264 estiver selecionado
            if (videoCodec.value === 'h264') {
                const selectedProfile = h264Profile.value;
                sdp = setH264Profile(sdp, selectedProfile);
            }
            
            // 3. Priorizar codec H264 para compatibilidade com iOS
            sdp = prioritizeCodec(sdp, 'video', 'H264');
        }

        // Aplicar a SDP modificada
        const modifiedOffer = new RTCSessionDescription({
            type: 'offer',
            sdp: sdp
        });

        await peerConnection.setLocalDescription(modifiedOffer);
        console.log("Descrição local definida com sucesso");

        // Adicionar informações sobre configurações da oferta para debug
        const offerInfo = {
            codec: videoCodec.value,
            profile: h264Profile.value,
            pixelFormat: pixelFormat.value,
            optimizedForIOS: optimizeForIOS || iosOptimize.checked
        };

        sendMessage({
            type: 'offer',
            sdp: peerConnection.localDescription.sdp,
            roomId: roomIdInput.value,
            offerInfo: offerInfo
        });
        
        connectionInfo.textContent = 'Status da conexão: Oferta enviada';
    } catch (error) {
        console.error('Erro ao criar oferta:', error);
        updateStatus(`Erro ao criar oferta WebRTC: ${error.message}`, 'offline');
        connectionInfo.textContent = 'Status da conexão: Erro ao criar oferta';
    }
}

// Helper para configurar bitrate específico na SDP
function setMediaBitrate(sdp, media, bitrate) {
    const lines = sdp.split('\n');
    let line = -1;

    // Encontrar a seção m=video
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('m=' + media)) {
            line = i;
            break;
        }
    }

    if (line === -1) {
        return sdp;
    }

    // Verificar se já existe uma linha b=AS
    let found = false;
    for (let i = line; i < lines.length; i++) {
        if (lines[i].startsWith('m=') && i !== line) break; // Próxima seção m=

        if (lines[i].startsWith('b=AS:')) {
            // Em vez de substituir, apenas modificamos se o valor for muito menor
            const currentBitrate = parseInt(lines[i].substring(5), 10);
            if (currentBitrate < bitrate) {
                lines[i] = 'b=AS:' + bitrate;
            }
            found = true;
            break;
        }
    }

    if (!found) {
        // Adicionar linha b= após a linha 'c=' que segue a seção m=
        let insertPosition = line + 1;
        while (insertPosition < lines.length && !lines[insertPosition].startsWith('c=')) {
            insertPosition++;
        }

        if (insertPosition < lines.length) {
            // Inserir após a linha c=
            insertPosition++;
            const newLines = lines.slice(0, insertPosition);
            newLines.push('b=AS:' + bitrate);
            newLines.push(...lines.slice(insertPosition));
            return newLines.join('\n');
        } else {
            // Caso não encontre a linha c=
            const newLines = lines.slice(0, line + 1);
            newLines.push('b=AS:' + bitrate);
            newLines.push(...lines.slice(line + 1));
            return newLines.join('\n');
        }
    }

    return lines.join('\n');
}

// Helper para adicionar preferência de formato de pixel
function addPixelFormatPreference(sdp, format) {
    // Manipulação específica de SDP para adicionar preferência de formato de pixel
    // Este é um placeholder simplificado - no ambiente real, seria necessário manipular
    // as linhas fmtp específicas para o codec H264
    return sdp;
}

// Helper para configurar perfil H264 específico
function setH264Profile(sdp, profile) {
    if (!profile) return sdp;
    
    const lines = sdp.split('\n');
    let mediaLine = -1;
    let h264PayloadType = null;
    
    // Primeiro encontrar a linha de mídia de vídeo
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('m=video')) {
            mediaLine = i;
            break;
        }
    }
    
    if (mediaLine === -1) return sdp;
    
    // Encontrar payload type para H264
    for (let i = mediaLine; i < lines.length; i++) {
        if (lines[i].startsWith('m=') && i !== mediaLine) break;
        
        if (lines[i].indexOf('a=rtpmap:') !== -1 && lines[i].indexOf('H264') !== -1) {
            h264PayloadType = lines[i].split(':')[1].split(' ')[0];
            break;
        }
    }
    
    if (!h264PayloadType) return sdp;
    
    // Procurar e modificar ou adicionar perfil H264
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].indexOf(`a=fmtp:${h264PayloadType}`) !== -1) {
            if (lines[i].indexOf('profile-level-id=') !== -1) {
                // Substituir perfil existente
                lines[i] = lines[i].replace(/profile-level-id=[^;]+/, `profile-level-id=${profile}`);
            } else {
                // Adicionar perfil se não existir
                lines[i] = `${lines[i]};profile-level-id=${profile}`;
            }
            break;
        }
    }
    
    return lines.join('\n');
}

// Helper para priorizar codec específico
function prioritizeCodec(sdp, mediaType, codecName) {
    const lines = sdp.split('\n');
    let mediaLine = -1;
    let codecPts = [];
    
    // Encontrar a linha de mídia
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].startsWith(`m=${mediaType}`)) {
            mediaLine = i;
            break;
        }
    }
    
    if (mediaLine === -1) return sdp;
    
    // Encontrar todos os payload types para o codec desejado
    for (let i = mediaLine + 1; i < lines.length; i++) {
        if (lines[i].startsWith('m=')) break;
        
        if (lines[i].startsWith('a=rtpmap:') && lines[i].includes(codecName)) {
            const pt = lines[i].split(':')[1].split(' ')[0];
            codecPts.push(pt);
        }
    }
    
    if (codecPts.length === 0) return sdp;
    
    // Reordenar payload types na linha de mídia para priorizar o codec
    const mLine = lines[mediaLine].split(' ');
    const payloadTypes = mLine.slice(3);
    
    // Remover os payload types do codec desejado
    const filteredPts = payloadTypes.filter(pt => !codecPts.includes(pt));
    
    // Reordenar com o codec desejado primeiro
    const newPts = [...codecPts, ...filteredPts];
    
    // Reconstruir a linha de mídia
    mLine.splice(3, payloadTypes.length, ...newPts);
    lines[mediaLine] = mLine.join(' ');
    
    return lines.join('\n');
}

// Atualizar status na interface
function updateStatus(message, state) {
    statusDiv.textContent = message;
    statusDiv.className = 'status-badge';
    
    switch (state) {
        case 'online':
            statusDiv.classList.add('status-online');
            break;
        case 'offline':
            statusDiv.classList.add('status-offline');
            break;
        case 'connecting':
            statusDiv.classList.add('status-connecting');
            statusDiv.classList.add('pulse');
            break;
        default:
            statusDiv.classList.add('status-offline');
    }
}

// Iniciar transmissão
async function startStreaming() {
    try {
        if (!roomIdInput.value.trim()) {
            alert("Por favor, informe um ID de sala");
            roomIdInput.classList.add('shake');
            setTimeout(() => roomIdInput.classList.remove('shake'), 500);
            return;
        }

        startButton.disabled = true;
        stopButton.disabled = false;

        // Desabilitar troca de qualidade durante streaming
        roomIdInput.disabled = true;
        videoSource.disabled = true;
        videoQuality.disabled = true;
        frameRate.disabled = true;
        videoCodec.disabled = true;
        h264Profile.disabled = true;
        pixelFormat.disabled = true;
        iosOptimize.disabled = true;

        updateStatus('Iniciando câmera...', 'connecting');
        connectionInfo.textContent = 'Status da conexão: Iniciando câmera';
        
        // Obter stream de vídeo com qualidade selecionada
        await getLocalMediaStream();
        
        updateStatus('Conectando ao servidor...', 'connecting');
        connectionInfo.textContent = 'Status da conexão: Conectando ao servidor';

        // Limpar flag de ofertas
        offerCreatedForRoom = {};

        // Configurar WebRTC
        setupPeerConnection();

        // Conectar ao servidor
        connectWebSocket();
    } catch (error) {
        console.error('Erro ao iniciar transmissão:', error);
        startButton.disabled = false;
        stopButton.disabled = true;
        roomIdInput.disabled = false;
        videoSource.disabled = false;
        videoQuality.disabled = false;
        frameRate.disabled = false;
        videoCodec.disabled = false;
        h264Profile.disabled = false;
        pixelFormat.disabled = false;
        iosOptimize.disabled = false;
        updateStatus(`Erro: ${error.message}`, 'offline');
        connectionInfo.textContent = `Status da conexão: Erro - ${error.message}`;
    }
}

// Parar transmissão
function stopStreaming(notifyServer = true) {
    startButton.disabled = false;
    stopButton.disabled = true;
    roomIdInput.disabled = false;
    videoSource.disabled = false;
    videoQuality.disabled = false;
    frameRate.disabled = false;
    videoCodec.disabled = false;
    h264Profile.disabled = false;
    pixelFormat.disabled = false;
    iosOptimize.disabled = false;

    // Limpar timeout de reconexão, se houver
    if (reconnectTimeout) {
        clearTimeout(reconnectTimeout);
        reconnectTimeout = null;
    }

    // Limpar flag de ofertas
    offerCreatedForRoom = {};

    // Enviar mensagem de despedida, apenas se solicitado
    if (notifyServer && ws && ws.readyState === WebSocket.OPEN) {
        sendMessage({
            type: 'bye',
            roomId: roomIdInput.value
        });
        
        console.log("Enviando mensagem 'bye' ao servidor");
        connectionInfo.textContent = 'Status da conexão: Enviando mensagem de encerramento';
        
        // Dar mais tempo para a mensagem ser enviada antes de fechar
        setTimeout(() => {
            console.log("Fechando conexões após envio de 'bye'");
            closeConnections();
        }, 1000); // Aumentado para 1 segundo
    } else {
        closeConnections();
    }
}

// Função separada para limpar recursos
function closeConnections() {
    // Parar monitoramento de estatísticas
    if (statsInterval) {
        clearInterval(statsInterval);
        statsInterval = null;
    }

    // Parar keep-alive
    stopKeepAliveTimer();

    // Fechar conexão WebRTC
    if (peerConnection) {
        peerConnection.close();
        peerConnection = null;
    }

    // Fechar WebSocket
    if (ws) {
        if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
            ws.close();
        }
        ws = null;
    }

    // Parar streams
    if (localStream) {
        localStream.getTracks().forEach(track => track.stop());
        localStream = null;
        localVideo.srcObject = null;
    }

    // Esconder painel de estatísticas
    statsPanel.classList.add('hidden');
    
    // Resetar contador de reconexão
    reconnectAttempts = 0;
    
    // Resetar timestamp do último pong
    lastPongReceived = 0;

    updateStatus('Desconectado', 'offline');
    connectionInfo.textContent = 'Status da conexão: Desconectado';
}

// Adicionar event listeners
startButton.addEventListener('click', startStreaming);
stopButton.addEventListener('click', () => stopStreaming(true));

// Verificar permissões de câmera quando mudar qualidade
videoQuality.addEventListener('change', async () => {
    if (!localStream && startButton.disabled === false) {
        try {
            // Mostrar preview quando o usuário mudar qualidade
            await getLocalMediaStream();
        } catch (error) {
            console.error("Erro ao atualizar stream:", error);
        }
    }
});

// Evento para mostrar preview quando mudar fonte de vídeo
videoSource.addEventListener('change', async () => {
    if (!localStream && startButton.disabled === false) {
        try {
            await getLocalMediaStream();
        } catch (error) {
            console.error("Erro ao trocar fonte de vídeo:", error);
        }
    }
});

// Adicionar tratamento para evitar timeout
window.addEventListener('focus', () => {
    // Quando a aba recebe foco, verificar se é necessário reconectar
    if (startButton.disabled && !stopButton.disabled && 
        (!ws || ws.readyState !== WebSocket.OPEN)) {
        console.log("Detectada aba inativa. Reconectando...");
        clearTimeout(reconnectTimeout);
        reconnectAttempts = 0;
        connectWebSocket();
    }
});

// Inicializar quando a página carregar
window.addEventListener('DOMContentLoaded', initialize);

// Detectar quando a página é fechada para limpar recursos
window.addEventListener('beforeunload', () => stopStreaming(true));