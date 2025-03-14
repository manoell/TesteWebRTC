WebRTC Camera Preview Tweak
Visão Geral do Projeto
Este projeto implementa um sistema de recepção WebRTC em alta qualidade para iOS, otimizado para substituição de feed de câmera. O sistema consiste em um servidor Node.js e um tweak para iOS jailbroken que trabalham em conjunto para fornecer streaming de vídeo em 4K a 60fps com mínima latência em redes locais.
Componentes Principais
1. Servidor WebRTC
Um servidor Node.js que funciona como ponto central de sinalização e roteamento de streams WebRTC.
Características:

Otimizado para redes locais com baixa latência
Suporte nativo para streaming em 4K/60fps
Compatibilidade direta com formatos preferidos do iOS
Sistema de sinalização WebSocket simplificado
Projetado para apenas duas conexões simultâneas (transmissor e receptor)
Configuração mínima necessária para operação

2. Cliente iOS (Tweak)
Um tweak para dispositivos iOS jailbroken que exibe uma janela flutuante com o preview do stream WebRTC recebido.
Características:

Janela flutuante interativa com controles de conexão
Recepção otimizada de streams WebRTC
Auto-reconexão em caso de falhas de rede
Sistema avançado de manipulação de frames
Adaptação automática com base nas dimensões da câmera iOS
Estatísticas de performance em tempo real
Preparado para futura substituição do feed de câmera

Arquitetura Técnica
Servidor

Tecnologias: Node.js, Express, WebSocket, WebRTC
Módulos principais:

server.js - Ponto de entrada e gerenciamento de WebSocket
webrtc-signaling.js - Lógica de sinalização WebRTC
stream-manager.js - Gerenciamento de streams e configurações



Cliente iOS

Componentes principais:

FloatingWindow - Interface de usuário e controles
WebRTCManager - Gerenciamento de conexão WebRTC e sinalização
WebRTCFrameConverter - Processamento e adaptação de frames
CameraHook (futura implementação) - Substituição do feed da câmera



Fluxo de Funcionamento

O Servidor WebRTC é iniciado em um computador na rede local
Um transmissor (navegador ou aplicativo) conecta-se ao servidor e inicia streaming em alta qualidade
O tweak iOS exibe uma janela flutuante no dispositivo
Ao clicar em "Ativar Preview", o tweak conecta-se ao servidor WebRTC
O tweak recebe o stream e exibe o preview na janela flutuante
O sistema mantém a conexão estável e se reconecta automaticamente em caso de falhas
Para encerrar, o usuário clica em "Desativar Preview"

Otimizações Específicas
Otimização para Rede Local

Desativação de ICE candidates externos (TURN/STUN)
Parâmetros de WebRTC otimizados para baixa latência
Keep-alive com intervalos reduzidos para detecção rápida de problemas

Processamento de Vídeo

Formatos de pixel nativos do iOS para minimizar conversões
Aceleração de hardware para processamento de frames
Pipeline otimizado para reduzir cópias de buffer
Adaptação automática das dimensões do vídeo

Conexão e Estabilidade

Sistema robusto de reconexão automática
Máquina de estados clara para gerenciamento de conexão
Gerenciamento centralizado de temporizadores
Tratamento apropriado de desconexões manuais vs. falhas

Preparação para Substituição de Câmera

Detecção automática de dimensões e FPS da câmera nativa
Sistema de adaptação para ajustar streams ao formato nativo
Compatibilidade com formatos de buffer do iOS
Otimização para performance em tempo real

Requisitos Técnicos
Servidor

Node.js 14.0+
Pacotes: express, ws, http, cors, uuid
Rede WiFi local estável
Capacidade de processar vídeo 4K/60fps

Cliente iOS

Dispositivo iOS jailbroken (iOS 14.0+)
Theos (ambiente de desenvolvimento para tweaks)
Dependências: WebRTC framework, AVFoundation

Configuração e Uso
Servidor

Instalar dependências: npm install
Iniciar servidor: node server.js
O servidor exibirá o IP e porta para conexão

Cliente iOS (Tweak)

Instalar via arquivo .deb ou compilar usando Theos
A janela flutuante aparecerá automaticamente
Configurar o IP do servidor na interface (se necessário)
Clicar em "Ativar Preview" para iniciar a recepção
Clicar em "Desativar Preview" para interromper

Diagnóstico e Monitoramento
A interface do tweak fornece informações em tempo real sobre:

Estado da conexão WebRTC
Qualidade do stream (resolução, FPS)
Estatísticas de rede (latência, perda de pacotes)
Logs simplificados para diagnóstico

Limitações Atuais

Funciona apenas em rede local WiFi para garantir latência mínima
Requer dispositivo iOS jailbroken
Suporta apenas uma conexão de visualização por vez
A substituição do feed da câmera é uma funcionalidade futura

Desenvolvimento Futuro

Implementação completa da substituição do feed da câmera
Suporte para mais opções de qualidade/desempenho
Interface de configuração aprimorada
Possibilidade de gravação do stream recebido


Este projeto é otimizado para desempenho, estabilidade e qualidade visual, priorizando o funcionamento perfeito em redes locais e a compatibilidade com o sistema de câmera do iOS para uma futura implementação de substituição de feed.
