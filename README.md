# WebRTC Camera Feed Replacement System

## Visão Geral do Projeto

Este projeto implementa um sistema WebRTC otimizado para substituir transparentemente o feed da câmera nativa do iOS. O sistema consiste em um servidor de sinalização WebRTC, uma interface web para transmissão, e um tweak iOS que primeiro exibe o stream em uma janela flutuante (para testes) e posteriormente substitui diretamente o feed da câmera nativa.

A meta final é uma substituição completamente transparente, onde qualquer aplicativo que use a câmera nativa (fotos, vídeos, apps de terceiros) receberá o stream WebRTC como se fosse o feed original da câmera, sem necessidade de modificações adicionais.

## Estado Atual do Código

| Arquivo | Descrição | Estado Atual |
|---------|-----------|--------|
| `server.js` | Servidor de sinalização WebRTC | Funcional, necessita otimização para formatos iOS |
| `index.html` | Interface web de transmissão | Funcional, necessita configurações de codecs iOS |
| `Tweak.xm` | Ponto de entrada do tweak | Funcional, necessita reorganização |
| `FloatingWindow.h/m` | Interface de preview | Funcional |
| `WebRTCManager.h/m` | Gerenciamento de conexão | Funcional, necessita otimização |
| `WebRTCFrameConverter.h/m` | Processamento de frames | Funcional, necessita compatibilidade com formatos iOS |
| `logger.h/m` | Sistema de logging | Funcional, bem implementado |
| `implemetacaoSubstituicao.txt` | Referência para substituição | Não implementado, apenas referência |

## Requisitos de Compatibilidade Identificados

Com base em análise de diagnóstico da câmera iOS, identificamos os seguintes requisitos críticos para a substituição transparente:

### 1. Formatos de Pixel
A câmera iOS utiliza principalmente três formatos:
- `420f` (YUV 4:2:0 full-range) - **Formato principal e prioritário**
- `420v` (YUV 4:2:0 video-range)
- `BGRA` (32-bit BGRA)

### 2. Resoluções
- Câmera traseira: 4032x3024 (12MP)
- Preview de câmera: 1334x750
- Renderização final: Adaptada para dimensões da tela (ex: 375x667)

### 3. Classes Principais de iOS para Hook
- `AVCaptureSession`: Controla toda a sessão de captura
- `AVCaptureVideoDataOutput`: Gerencia saída de vídeo e delegates
- `AVCaptureConnection`: Gerencia orientação e espelhamento

### 4. Métodos Críticos para Interceptação
- `AVCaptureSession startRunning`
- `AVCaptureVideoDataOutput setSampleBufferDelegate:`
- `AVCaptureConnection setVideoOrientation:`
- `AVCaptureConnection setVideoMirrored:`

## Plano de Reorganização e Otimização

Antes de implementar a substituição, é necessário reorganizar e otimizar o código existente:

### 1. Otimização do Servidor WebRTC
- **Configuração de codec nativo iOS:**
  - Configurar transmissor para usar H.264 com perfil compatível com iOS
  - Implementar sinalização otimizada para formatos YUV 4:2:0
  - Priorizar transmissão diretamente em formato `420f` quando possível

- **Adaptação de resolução no servidor:**
  - Permitir configurações de resolução específicas para iOS
  - Implementar escalonamento inteligente baseado em capacidade de rede

### 2. Reorganização do WebRTCFrameConverter
- **Suporte nativo a formatos iOS:**
  - Implementar processamento eficiente para `420f` (YUV 4:2:0 full-range)
  - Minimizar conversões entre formatos
  - Utilizar aceleração de hardware para conversões necessárias

- **Adaptação inteligente de resolução:**
  - Criar sistema que detecta resolução da câmera ativa
  - Adaptar dinâmica e eficientemente para qualquer resolução

### 3. Refatoração do WebRTCManager
- **Otimização de desempenho:**
  - Melhorar gerenciamento de memória e recursos
  - Implementar reconexão inteligente
  - Otimizar processamento de sinalização

- **Preparação para integração final:**
  - Implementar API clara para obtenção de frames
  - Criar sistema de callback para eventos de câmera
  - Estruturar para interação transparente com subsistema de câmera

### 4. Reformulação da Interface de Preview (FloatingWindow)
- **Separação de responsabilidades:**
  - Isolar UI de preview da lógica de gerenciamento
  - Implementar sistema de estados mais robusto
  
- **Interface para debugging:**
  - Adicionar estatísticas avançadas de desempenho
  - Criar visualização de diagnóstico para formatos de pixel
  - Implementar controles para testes de injeção de feed

## Arquitetura para Substituição Direta da Câmera

Para substituir diretamente o feed da câmera, permitindo funcionamento transparente com todos os apps, implementaremos:

### 1. Hook Primário em AVCaptureSession
Este é o ponto mais fundamental para interceptação, permitindo substituir o feed no nível mais básico:
```objective-c
%hook AVCaptureSession

- (void)startRunning {
    // Configurar injeção de feed antes da execução original
    %orig;
    // Ativar substituição após inicialização original
}

%end
```

### 2. Gerenciamento de Delegates e Outputs
Para garantir que o feed substituto seja entregue a todos os delegates:
```objective-c
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    // Registrar o delegate original
    // Configurar interceptação de frames
    %orig;
}

%end
```

### 3. Sistema de Injeção de Frames Adaptativo
```objective-c
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)originalBuffer fromConnection:(AVCaptureConnection *)connection {
    // Se substituição ativa, substituir buffer com feed WebRTC
    // Se não, passar buffer original
    
    // Adaptar formato, resolução e orientação
    // Encaminhar para delegate original
}
```

### 4. Gerenciamento de Propriedades de Vídeo
```objective-c
%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation {
    %orig;
    // Atualizar orientação do feed substituto para manter sincronização
}

- (void)setVideoMirrored:(BOOL)mirrored {
    %orig;
    // Atualizar espelhamento do feed substituto
}

%end
```

## Próximos Passos Técnicos

### Fase 1: Otimização de Transmissão
1. **Configurar servidor para transmitir em formato nativo iOS:**
   - Implementar sinalização otimizada para formato `420f`
   - Configurar codec H.264 com perfil adequado ao iOS
   - Implementar negociação de resolução e framerate

2. **Otimizar página de transmissão:**
   - Permitir seleção de formato específico para iOS
   - Implementar controles avançados de qualidade
   - Desenvolver estatísticas detalhadas em tempo real

### Fase 2: Reorganização do Código Existente
1. **Refatorar WebRTCFrameConverter:**
   - Implementar suporte direto a formatos iOS
   - Otimizar pipeline de processamento para minimizar latência
   - Criar sistema eficiente de adaptação de resolução

2. **Reescrever WebRTCManager:**
   - Separar lógica de conexão da lógica de processamento
   - Implementar padrão de delegate mais eficiente
   - Otimizar gerenciamento de recursos

3. **Aprimorar FloatingWindow:**
   - Melhorar feedback visual de estatísticas
   - Implementar diagnóstico de formatos e qualidade
   - Aperfeiçoar tratamento de eventos e gestos

### Fase 3: Implementação do Subsistema de Substituição
1. **Criar Framework de Substituição:**
   - Desenvolver APIs para injeção de frames
   - Implementar mecanismo de interceptação de delegates
   - Criar sistema para adaptação dinâmica às condições da câmera

2. **Implementar Hooks de Sistemas:**
   - Criar hooks precisos para classes AVCapture
   - Implementar intercepção de eventos da câmera
   - Desenvolver sistema transparente de passagem ou substituição

3. **Desenvolver Sistema de Diagnóstico:**
   - Criar logs detalhados específicos para substituição
   - Implementar detecção de problemas em tempo real
   - Desenvolver ferramentas visuais de debugging

## Configuração do Ambiente

### Requisitos do Servidor
- Node.js 14.0+
- Dependências: express, ws, http, cors, uuid
- Configuração de rede: porta 8080 acessível na rede local

### Requisitos do Cliente iOS
- iOS 14.0+ jailbroken
- Theos instalado para compilação
- CocoaPods para gerenciamento de dependências
- WebRTC framework instalado

### Compilação e Instalação
```bash
# Instalar dependências
pod install

# Compilar tweak
make package

# Instalar no dispositivo
make install THEOS_DEVICE_IP=<ip_do_dispositivo>
```

## Uso Atual (Fase de Preview)

### Iniciar Servidor
```bash
node server.js
```

### Transmitir Vídeo
1. Acesse `http://<ip_do_servidor>:8080` em um navegador
2. Selecione a qualidade e a fonte de vídeo
3. Inicie a transmissão

### Visualizar no dispositivo iOS
1. A janela flutuante aparecerá no iOS
2. Toque em "Ativar Preview" para visualizar o stream
3. Use gestos para mover e interagir com a janela

## Dicas de Desenvolvimento e Testes

### Logging e Diagnóstico
- Configure o nível de log em `Tweak.xm`:
  ```objective-c
  setLogLevel(5); // Nível máximo para desenvolvimento
  ```
- Consulte logs em `/var/tmp/testeWebRTC.log`

### Métricas de Performance
Para monitorar o desempenho durante o desenvolvimento:
- Latência: ideal < 100ms para experiência realista
- Uso de CPU: manter abaixo de 20% para estabilidade
- Uso de memória: evitar crescimento contínuo

### Testes de Compatibilidade
Testar com vários aplicativos que utilizam a câmera:
- Câmera nativa do iOS (fotos e vídeos)
- FaceTime e chamadas de vídeo
- Apps populares de terceiros (Instagram, Snapchat, etc.)

---

Este projeto visa criar um sistema completo que permite substituir o feed da câmera nativa do iOS no nível mais fundamental possível, de modo que qualquer aplicativo que utilize AVFoundation receba o stream WebRTC como se fosse a câmera original, sem necessidade de modificações adicionais. A reorganização e otimização do código atual são essenciais antes da implementação desta substituição.
