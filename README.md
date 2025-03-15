# WebRTC Camera Preview Tweak

## Visão Geral do Projeto

Este projeto implementa um sistema avançado de recepção WebRTC em alta qualidade para iOS, otimizado para visualização e futura substituição de feed de câmera. O sistema consiste em um servidor Node.js e um tweak para iOS jailbroken que trabalham em conjunto para fornecer streaming de vídeo em 4K a 60fps com mínima latência em redes locais.

### Objetivos Principais

- Receber e processar streams WebRTC em alta qualidade (até 4K/60fps)
- Oferecer preview em janela flutuante interativa com múltiplos gestos e estados
- Adaptar automaticamente à resolução e FPS da câmera nativa do iOS
- Fornecer diagnóstico avançado e monitoramento de performance em tempo real
- Preparar estrutura para futura substituição do feed da câmera
- Otimizar para baixa latência e alta performance em redes locais

## Componentes Principais

### 1. Servidor WebRTC

Um servidor Node.js que funciona como ponto central de sinalização e roteamento de streams WebRTC.

**Características:**
- Otimizado para redes locais com baixa latência
- Suporte nativo para streaming em 4K/60fps
- Compatibilidade direta com formatos preferidos do iOS
- Sistema de sinalização WebSocket simplificado
- Projetado para apenas duas conexões simultâneas (transmissor e receptor)
- Configuração mínima necessária para operação

### 2. Cliente iOS (Tweak)

Um tweak para dispositivos iOS jailbroken que exibe uma janela flutuante com o preview do stream WebRTC recebido.

**Características:**
- Janela flutuante interativa com controles de conexão
- Sistema de gestos intuitivos (arrastar, pinçar, toques)
- Auto-adaptação para diferentes estados (normal, minimizado, expandido, tela cheia)
- Recepção otimizada de streams WebRTC
- Auto-reconexão em caso de falhas de rede
- Sistema avançado de manipulação de frames
- Adaptação automática com base nas dimensões da câmera iOS
- Estatísticas de performance em tempo real
- Sistema de diagnóstico integrado
- Preparado para futura substituição do feed de câmera

## Arquitetura Técnica

### Servidor

**Tecnologias:** Node.js, Express, WebSocket, WebRTC

**Módulos principais:**
- `server.js` - Ponto de entrada e gerenciamento de WebSocket
- `webrtc-signaling.js` - Lógica de sinalização WebRTC
- `stream-manager.js` - Gerenciamento de streams e configurações

### Cliente iOS

**Componentes principais:**
- `FloatingWindow` - Interface de usuário interativa com múltiplos gestos e estados
- `WebRTCManager` - Gerenciamento de conexão WebRTC e sinalização
- `WebRTCFrameConverter` - Processamento e adaptação de frames
- `WebRTCDiagnostics` - Sistema de diagnóstico e monitoramento de performance
- `logger` - Sistema avançado de logging com níveis e rotação de arquivos
- `CameraHook` (futura implementação) - Substituição do feed da câmera

## Fluxo de Funcionamento

1. O Servidor WebRTC é iniciado em um computador na rede local
2. Um transmissor (navegador ou aplicativo) conecta-se ao servidor e inicia streaming em alta qualidade
3. O tweak iOS exibe uma janela flutuante no dispositivo
4. Ao clicar em "Ativar Preview", o tweak conecta-se ao servidor WebRTC
5. O tweak recebe o stream e exibe o preview na janela flutuante
6. O usuário pode interagir com a janela usando gestos:
   - Arrastar para mover
   - Duplo toque para alternar entre estados
   - Pinçar para redimensionar
   - Toque único para mostrar/ocultar controles
   - Toque longo para menu de configurações
7. O sistema de diagnóstico monitora continuamente a performance
8. Para encerrar, o usuário clica em "Desativar Preview"

## Otimizações Específicas

### Otimização para Rede Local
- Desativação de ICE candidates externos (TURN/STUN)
- Parâmetros de WebRTC otimizados para baixa latência
- Keep-alive com intervalos reduzidos para detecção rápida de problemas

### Processamento de Vídeo
- Formatos de pixel nativos do iOS para minimizar conversões
- Aceleração de hardware para processamento de frames
- Pipeline otimizado para reduzir cópias de buffer
- Adaptação automática das dimensões do vídeo

### Interface do Usuário
- Gestos intuitivos para controle da janela flutuante
- Feedback visual e tátil para melhor experiência
- Auto-ocultação de controles para visualização limpa
- Diferentes estados para adaptação ao contexto de uso
- Animações suaves para transições entre estados

### Diagnóstico e Monitoramento
- Sistema de logging com múltiplos níveis de detalhe
- Monitoramento em tempo real de métricas de performance
- Detecção automática de problemas e recomendações
- Relatórios detalhados para análise e depuração
- Estatísticas de rede e vídeo para avaliação de qualidade

### Conexão e Estabilidade
- Sistema robusto de reconexão automática
- Máquina de estados clara para gerenciamento de conexão
- Gerenciamento centralizado de temporizadores
- Tratamento apropriado de desconexões manuais vs. falhas

### Preparação para Substituição de Câmera
- Detecção automática de dimensões e FPS da câmera nativa
- Sistema de adaptação para ajustar streams ao formato nativo
- Compatibilidade com formatos de buffer do iOS
- Otimização para performance em tempo real

## Requisitos Técnicos

### Servidor
- Node.js 14.0+
- Pacotes: express, ws, http, cors, uuid
- Rede WiFi local estável
- Capacidade de processar vídeo 4K/60fps

### Cliente iOS
- Dispositivo iOS jailbroken (iOS 14.0+)
- Theos (ambiente de desenvolvimento para tweaks)
- Dependências: WebRTC framework, AVFoundation

## Instalação e Configuração

### Servidor
1. Instalar Node.js 14.0 ou superior
2. Clonar o repositório
3. Executar `npm install` na pasta `server` para instalar dependências
4. Iniciar o servidor com `node server.js`
5. O servidor exibirá o IP e porta para conexão

### Cliente iOS (Tweak)
1. Configurar ambiente Theos no macOS
2. Instalar CocoaPods e executar `pod install` para obter o framework WebRTC
3. Compilar o tweak usando `make package` no diretório do projeto
4. Instalar o pacote .deb gerado no dispositivo iOS jailbroken
5. O tweak será iniciado automaticamente com o SpringBoard

## Uso

### Transmissor
1. Abra a página HTML do transmissor no navegador
2. Selecione a qualidade desejada (recomendado 4K/60fps para máxima qualidade)
3. Clique em "Iniciar Transmissão"

### Receptor (iOS)
1. A janela flutuante aparecerá automaticamente na tela
2. Clique no botão "Ativar Preview" para iniciar a recepção
3. Use gestos para interagir com a janela:
   - Arraste para mover
   - Toque duplo para alternar entre normal/minimizado/expandido/tela cheia
   - Pinçe para redimensionar
   - Toque único para mostrar/ocultar controles
   - Toque longo para mostrar menu de opções
4. Observe as informações de status e estatísticas para verificar a qualidade da conexão
5. Para encerrar, clique em "Desativar Preview"

## Diagnóstico e Monitoramento

A interface do tweak fornece informações em tempo real sobre:
- Estado da conexão WebRTC
- Qualidade do stream (resolução, FPS)
- Estatísticas de rede (latência, perda de pacotes)
- Alertas sobre problemas detectados
- Logs detalhados em `/var/tmp/testeWebRTC.log`

### Níveis de Log
- 0 = Sem logging
- 1 = Apenas erros críticos
- 2 = Erros
- 3 = Avisos e erros (padrão)
- 4 = Informações, avisos e erros
- 5 = Verbose (todos os logs)

## Limitações Atuais
- Funciona apenas em rede local WiFi para garantir latência mínima
- Requer dispositivo iOS jailbroken
- Suporta apenas uma conexão de visualização por vez
- A substituição do feed da câmera é uma funcionalidade futura

## Desenvolvimento Futuro
- Implementação completa da substituição do feed da câmera
- Suporte para mais opções de qualidade/desempenho
- Interface de configuração aprimorada
- Possibilidade de gravação do stream recebido
- Suporte a múltiplas fontes de vídeo

## Estrutura de Arquivos

```
WebRTCTweak/
├── server/
│   ├── server.js                # Servidor WebRTC principal
│   ├── package.json             # Dependências do servidor
│   └── index.html               # Interface do transmissor
├── tweak/
│   ├── Tweak.xm                 # Ponto de entrada do tweak
│   ├── FloatingWindow.h         # Definição da janela flutuante
│   ├── FloatingWindow.m         # Implementação da janela flutuante
│   ├── WebRTCManager.h          # Gerenciador de conexão WebRTC
│   ├── WebRTCManager.m          # Implementação do gerenciador
│   ├── WebRTCFrameConverter.h   # Conversor de frames WebRTC
│   ├── WebRTCFrameConverter.m   # Implementação do conversor
│   ├── WebRTCDiagnostics.h      # Sistema de diagnóstico
│   ├── WebRTCDiagnostics.m      # Implementação do diagnóstico
│   ├── logger.h                 # Sistema de logging
│   ├── logger.m                 # Implementação do logging
│   ├── Makefile                 # Configuração de compilação
│   ├── control                  # Metadados do pacote
│   └── Podfile                  # Dependências CocoaPods
└── README.md                    # Documentação do projeto
```

## Resolução de Problemas

### Problemas de Conexão
- Verifique se o servidor está acessível na rede local
- Garanta que as portas necessárias (8080) estão abertas no firewall
- Verifique os logs do servidor para mensagens de erro

### Problemas de Qualidade
- Reduza a resolução ou FPS se a rede não suportar 4K/60fps
- Verifique se há interferência na rede WiFi
- Consulte o relatório de diagnóstico para identificar gargalos

### Crashes do Tweak
- Verifique os logs em `/var/tmp/testeWebRTC.log`
- Reinicie o SpringBoard para reiniciar o tweak
- Verifique se o framework WebRTC está instalado corretamente

## Notas de Performance

Para obter o melhor desempenho possível:
- Use rede WiFi 5GHz ou superior
- Minimize a distância entre servidor e dispositivo iOS
- Reduza o tráfego de rede durante o uso
- Considere o uso de conexão Ethernet no lado do servidor
- Minimize outros processos no dispositivo iOS durante o uso

---

Este projeto é otimizado para desempenho, estabilidade e qualidade visual, priorizando o funcionamento perfeito em redes locais e a compatibilidade com o sistema de câmera do iOS para uma futura implementação de substituição de feed.
