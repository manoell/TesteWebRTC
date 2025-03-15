#import "WebRTCDiagnostics.h"
#import "logger.h"

// Chaves para eventos e métricas
static NSString * const kEventTypeConnection = @"connection";
static NSString * const kEventTypeVideo = @"video";
static NSString * const kEventTypeNetwork = @"network";
static NSString * const kEventTypeError = @"error";
static NSString * const kEventTypeSystem = @"system";

// Limiares para detecção de problemas
static const float kHighRttThreshold = 150.0f;        // RTT > 150ms é alto
static const float kCriticalRttThreshold = 300.0f;    // RTT > 300ms é crítico
static const float kPacketLossWarningThreshold = 1.0f; // 1% perda é aviso
static const float kPacketLossCriticalThreshold = 5.0f; // 5% perda é crítico
static const float kLowFpsThreshold = 15.0f;          // Menos que 15fps é baixo
static const float kJitterWarningThreshold = 30.0f;   // Jitter > 30ms é aviso

@interface WebRTCDiagnostics ()

// Armazenamento de métricas e eventos
@property (nonatomic, strong) NSMutableArray *events;
@property (nonatomic, strong) NSMutableDictionary *currentMetrics;
@property (nonatomic, strong) NSMutableArray *videoMetricsHistory;
@property (nonatomic, strong) NSMutableArray *networkMetricsHistory;
@property (nonatomic, strong) NSMutableArray *errors;

// Estado de monitoramento
@property (nonatomic, assign) BOOL isMonitoring;
@property (nonatomic, strong) NSTimer *monitoringTimer;
@property (nonatomic, assign) NSTimeInterval monitoringInterval;
@property (nonatomic, strong) NSDate *startTime;

// Dados para análise de tendências
@property (nonatomic, assign) float avgRtt;
@property (nonatomic, assign) float avgPacketLoss;
@property (nonatomic, assign) float avgFps;
@property (nonatomic, assign) float peakRtt;
@property (nonatomic, assign) int connectivityIssuesCount;
@property (nonatomic, assign) int framesDropped;

// Lock para acesso thread-safe
@property (nonatomic, strong) NSLock *dataLock;

// Diretório para armazenamento de logs
@property (nonatomic, strong) NSString *diagnosticsDirectory;

@end

@implementation WebRTCDiagnostics

#pragma mark - Singleton

+ (instancetype)sharedInstance {
    static WebRTCDiagnostics *sharedInstance = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupDiagnostics];
    }
    return self;
}

- (void)setupDiagnostics {
    self.events = [NSMutableArray array];
    self.currentMetrics = [NSMutableDictionary dictionary];
    self.videoMetricsHistory = [NSMutableArray array];
    self.networkMetricsHistory = [NSMutableArray array];
    self.errors = [NSMutableArray array];
    
    self.isMonitoring = NO;
    self.monitoringInterval = 2.0;
    self.startTime = [NSDate date];
    
    self.avgRtt = 0.0;
    self.avgPacketLoss = 0.0;
    self.avgFps = 0.0;
    self.peakRtt = 0.0;
    self.connectivityIssuesCount = 0;
    self.framesDropped = 0;
    
    // Criar lock para acesso thread-safe
    self.dataLock = [[NSLock alloc] init];
    
    // Configurar diretório de diagnóstico
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];
    self.diagnosticsDirectory = [documentsDirectory stringByAppendingPathComponent:@"WebRTCDiagnostics"];
    
    // Criar diretório se não existir
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:self.diagnosticsDirectory]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:self.diagnosticsDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error];
        
        if (error) {
            writeErrorLog(@"[WebRTCDiagnostics] Erro ao criar diretório de diagnósticos: %@", error);
        }
    }
    
    writeLog(@"[WebRTCDiagnostics] Sistema de diagnóstico inicializado");
    
    // Registrar informações do sistema
    [self logSystemInfo];
}

#pragma mark - Monitoring Control

- (void)startMonitoring:(NSTimeInterval)interval {
    [self.dataLock lock];
    
    if (self.isMonitoring) {
        [self stopMonitoring];
    }
    
    self.monitoringInterval = (interval > 0) ? interval : 2.0;
    self.isMonitoring = YES;
    self.startTime = [NSDate date];
    
    // Iniciar timer para coleta periódica
    self.monitoringTimer = [NSTimer scheduledTimerWithTimeInterval:self.monitoringInterval
                                                          target:self
                                                        selector:@selector(collectPeriodicMetrics)
                                                        userInfo:nil
                                                         repeats:YES];
    
    [self logEvent:kEventTypeSystem type:@"monitoring_started" details:@{
        @"interval": @(self.monitoringInterval),
        @"timestamp": [NSDate date]
    }];
    
    writeLog(@"[WebRTCDiagnostics] Monitoramento iniciado com intervalo de %.1f segundos", self.monitoringInterval);
    
    [self.dataLock unlock];
}

- (void)stopMonitoring {
    [self.dataLock lock];
    
    if (self.monitoringTimer) {
        [self.monitoringTimer invalidate];
        self.monitoringTimer = nil;
    }
    
    self.isMonitoring = NO;
    
    [self logEvent:kEventTypeSystem type:@"monitoring_stopped" details:@{
        @"duration": @([[NSDate date] timeIntervalSinceDate:self.startTime]),
        @"timestamp": [NSDate date]
    }];
    
    writeLog(@"[WebRTCDiagnostics] Monitoramento parado após %.1f segundos",
             [[NSDate date] timeIntervalSinceDate:self.startTime]);
    
    [self.dataLock unlock];
}

- (void)collectPeriodicMetrics {
    // Este método é chamado pelo timer para coletar métricas periódicas
    // e analisar tendências
    
    // Não precisamos de lock aqui porque já temos dados do momento atual,
    // e vamos apenas analisar tendências
    
    // Verificar se houve deterioração na qualidade da rede
    if (self.networkMetricsHistory.count >= 2) {
        NSDictionary *current = [self.networkMetricsHistory lastObject];
        NSDictionary *previous = self.networkMetricsHistory[self.networkMetricsHistory.count - 2];
        
        float currentRtt = [current[@"rtt"] floatValue];
        float previousRtt = [previous[@"rtt"] floatValue];
        
        // Se houver deterioração significativa, registrar
        if (currentRtt > previousRtt * 1.5 && currentRtt > kHighRttThreshold) {
            writeWarningLog(@"[WebRTCDiagnostics] Deterioração na qualidade da rede detectada. RTT: %.1f -> %.1f ms",
                           previousRtt, currentRtt);
            
            [self logEvent:kEventTypeNetwork type:@"quality_deterioration" details:@{
                @"previous_rtt": @(previousRtt),
                @"current_rtt": @(currentRtt),
                @"change_percent": @((currentRtt - previousRtt) / previousRtt * 100.0)
            }];
        }
    }
    
    // Verificar se houve queda no framerate
    if (self.videoMetricsHistory.count >= 2) {
        NSDictionary *current = [self.videoMetricsHistory lastObject];
        NSDictionary *previous = self.videoMetricsHistory[self.videoMetricsHistory.count - 2];
        
        float currentFps = [current[@"fps"] floatValue];
        float previousFps = [previous[@"fps"] floatValue];
        
        // Se houver queda significativa, registrar
        if (previousFps > 0 && currentFps < previousFps * 0.7 && currentFps < kLowFpsThreshold) {
            writeWarningLog(@"[WebRTCDiagnostics] Queda significativa no framerate detectada. FPS: %.1f -> %.1f",
                           previousFps, currentFps);
            
            [self logEvent:kEventTypeVideo type:@"framerate_drop" details:@{
                @"previous_fps": @(previousFps),
                @"current_fps": @(currentFps),
                @"change_percent": @((currentFps - previousFps) / previousFps * 100.0)
            }];
        }
    }
    
    // Atualizar médias em execução
    [self updateAverages];
}

- (void)updateAverages {
    float totalRtt = 0;
    float totalPacketLoss = 0;
    float totalFps = 0;
    int rttCount = 0;
    int packetLossCount = 0;
    int fpsCount = 0;
    
    // Calcular médias de rede
    for (NSDictionary *metrics in self.networkMetricsHistory) {
        if (metrics[@"rtt"]) {
            totalRtt += [metrics[@"rtt"] floatValue];
            rttCount++;
            
            // Atualizar RTT de pico
            float rtt = [metrics[@"rtt"] floatValue];
            if (rtt > self.peakRtt) {
                self.peakRtt = rtt;
            }
        }
        
        if (metrics[@"packetLoss"]) {
            totalPacketLoss += [metrics[@"packetLoss"] floatValue];
            packetLossCount++;
        }
    }
    
    // Calcular médias de vídeo
    for (NSDictionary *metrics in self.videoMetricsHistory) {
        if (metrics[@"fps"]) {
            totalFps += [metrics[@"fps"] floatValue];
            fpsCount++;
        }
    }
    
    // Atualizar médias
    self.avgRtt = rttCount > 0 ? totalRtt / rttCount : 0;
    self.avgPacketLoss = packetLossCount > 0 ? totalPacketLoss / packetLossCount : 0;
    self.avgFps = fpsCount > 0 ? totalFps / fpsCount : 0;
}

#pragma mark - Logging Methods

- (void)logConnectionEvent:(NSString *)eventType details:(NSDictionary *)details {
    [self.dataLock lock];
    
    NSMutableDictionary *eventDetails = [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
    [eventDetails setObject:[NSDate date] forKey:@"timestamp"];
    [eventDetails setObject:eventType forKey:@"type"];
    
    [self logEvent:kEventTypeConnection type:eventType details:eventDetails];
    
    // Verificar se é um evento de conectividade
    if ([eventType isEqualToString:@"disconnected"] ||
        [eventType isEqualToString:@"failed"] ||
        [eventType isEqualToString:@"error"]) {
        self.connectivityIssuesCount++;
    }
    
    writeLog(@"[WebRTCDiagnostics] Evento de conexão registrado: %@", eventType);
    
    [self.dataLock unlock];
}

- (void)logVideoMetrics:(CGSize)resolution fps:(float)fps bitrate:(float)bitrate {
    [self.dataLock lock];
    
    NSMutableDictionary *metrics = [NSMutableDictionary dictionary];
    [metrics setObject:[NSDate date] forKey:@"timestamp"];
    [metrics setObject:[NSValue valueWithCGSize:resolution] forKey:@"resolution"];
    [metrics setObject:@(fps) forKey:@"fps"];
    [metrics setObject:@(bitrate) forKey:@"bitrate"];
    
    [self.videoMetricsHistory addObject:metrics];
    
    // Manter histórico limitado
    if (self.videoMetricsHistory.count > 100) {
        [self.videoMetricsHistory removeObjectAtIndex:0];
    }
    
    // Atualizar métricas atuais
    [self.currentMetrics setObject:metrics forKey:kEventTypeVideo];
    
    // Registrar no log para eventos significativos
    if (fps < kLowFpsThreshold) {
        writeWarningLog(@"[WebRTCDiagnostics] FPS baixo detectado: %.1f fps", fps);
    }
    
    if (self.videoMetricsHistory.count % 10 == 0) {
        writeVerboseLog(@"[WebRTCDiagnostics] Métricas de vídeo: %dx%d @ %.1f fps, %.1f kbps",
                      (int)resolution.width, (int)resolution.height, fps, bitrate);
    }
    
    [self.dataLock unlock];
}

- (void)logNetworkMetrics:(float)rtt packetLoss:(float)packetLoss jitter:(float)jitter {
    [self.dataLock lock];
    
    NSMutableDictionary *metrics = [NSMutableDictionary dictionary];
    [metrics setObject:[NSDate date] forKey:@"timestamp"];
    [metrics setObject:@(rtt) forKey:@"rtt"];
    [metrics setObject:@(packetLoss) forKey:@"packetLoss"];
    [metrics setObject:@(jitter) forKey:@"jitter"];
    
    [self.networkMetricsHistory addObject:metrics];
    
    // Manter histórico limitado
    if (self.networkMetricsHistory.count > 100) {
        [self.networkMetricsHistory removeObjectAtIndex:0];
    }
    
    // Atualizar métricas atuais
    [self.currentMetrics setObject:metrics forKey:kEventTypeNetwork];
    
    // Registrar avisos para problemas de rede
    if (rtt > kCriticalRttThreshold) {
        writeErrorLog(@"[WebRTCDiagnostics] RTT crítico detectado: %.1f ms", rtt);
    } else if (rtt > kHighRttThreshold) {
        writeWarningLog(@"[WebRTCDiagnostics] RTT alto detectado: %.1f ms", rtt);
    }
    
    if (packetLoss > kPacketLossCriticalThreshold) {
        writeErrorLog(@"[WebRTCDiagnostics] Perda de pacotes crítica: %.1f%%", packetLoss);
    } else if (packetLoss > kPacketLossWarningThreshold) {
        writeWarningLog(@"[WebRTCDiagnostics] Perda de pacotes alta: %.1f%%", packetLoss);
    }
    
    if (jitter > kJitterWarningThreshold) {
        writeWarningLog(@"[WebRTCDiagnostics] Jitter alto detectado: %.1f ms", jitter);
    }
    
    if (self.networkMetricsHistory.count % 10 == 0) {
        writeVerboseLog(@"[WebRTCDiagnostics] Métricas de rede: RTT=%.1f ms, Perda=%.1f%%, Jitter=%.1f ms",
                      rtt, packetLoss, jitter);
    }
    
    [self.dataLock unlock];
}

- (void)logCriticalError:(NSString *)error code:(int)errorCode details:(NSDictionary *)details {
    [self.dataLock lock];
    
    NSMutableDictionary *errorInfo = [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
    [errorInfo setObject:[NSDate date] forKey:@"timestamp"];
    [errorInfo setObject:error forKey:@"message"];
    [errorInfo setObject:@(errorCode) forKey:@"code"];
    
    [self.errors addObject:errorInfo];
    
    // Registrar no log
    writeCriticalLog(@"[WebRTCDiagnostics] ERRO CRÍTICO: [%d] %@", errorCode, error);
    
    // Adicionar ao registro de eventos
    [self logEvent:kEventTypeError type:@"critical" details:errorInfo];
    
    [self.dataLock unlock];
}

- (void)logEvent:(NSString *)category type:(NSString *)type details:(NSDictionary *)details {
    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    [event setObject:[NSDate date] forKey:@"timestamp"];
    [event setObject:category forKey:@"category"];
    [event setObject:type forKey:@"type"];
    
    if (details) {
        [event setObject:details forKey:@"details"];
    }
    
    [self.events addObject:event];
    
    // Manter histórico limitado
    if (self.events.count > 1000) {
        [self.events removeObjectAtIndex:0];
    }
}

- (void)logSystemInfo {
    UIDevice *device = [UIDevice currentDevice];
    NSMutableDictionary *systemInfo = [NSMutableDictionary dictionary];
    
    // Informações do dispositivo
    [systemInfo setObject:device.name forKey:@"deviceName"];
    [systemInfo setObject:device.model forKey:@"deviceModel"];
    [systemInfo setObject:device.systemName forKey:@"systemName"];
    [systemInfo setObject:device.systemVersion forKey:@"systemVersion"];
    
    // Informações de memória
    float totalMemory = [[NSProcessInfo processInfo] physicalMemory] / (1024.0 * 1024.0 * 1024.0);
    [systemInfo setObject:@(totalMemory) forKey:@"totalMemoryGB"];
    
    // Informações de armazenamento
    NSError *error = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:&error];
    
    if (!error) {
        NSNumber *freeSize = [attrs objectForKey:NSFileSystemFreeSize];
        NSNumber *totalSize = [attrs objectForKey:NSFileSystemSize];
        
        double freeSizeGB = [freeSize doubleValue] / (1024.0 * 1024.0 * 1024.0);
        double totalSizeGB = [totalSize doubleValue] / (1024.0 * 1024.0 * 1024.0);
        
        [systemInfo setObject:@(freeSizeGB) forKey:@"freeStorageGB"];
        [systemInfo setObject:@(totalSizeGB) forKey:@"totalStorageGB"];
    }
    
    // Informações de rede
    NSString *networkType = @"Unknown";
    // Em uma implementação real, usar Reachability para detecção de tipo de rede
    [systemInfo setObject:networkType forKey:@"networkType"];
    
    [self logEvent:kEventTypeSystem type:@"system_info" details:systemInfo];
    
    writeLog(@"[WebRTCDiagnostics] Informações do sistema registradas: %@ %@ iOS %@",
             device.model, device.name, device.systemVersion);
}

#pragma mark - Reporting & Analysis

- (NSString *)generateDiagnosticReport {
    [self.dataLock lock];
    
    NSMutableString *report = [NSMutableString string];
    
    // Cabeçalho do relatório
    [report appendString:@"============================================\n"];
    [report appendString:@"         RELATÓRIO DE DIAGNÓSTICO WebRTC         \n"];
    [report appendString:@"============================================\n\n"];
    
    // Data e hora
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    [report appendFormat:@"Gerado em: %@\n", [formatter stringFromDate:[NSDate date]]];
    
    // Duração da sessão
    NSTimeInterval sessionDuration = [[NSDate date] timeIntervalSinceDate:self.startTime];
    int hours = (int)sessionDuration / 3600;
    int minutes = ((int)sessionDuration % 3600) / 60;
    int seconds = (int)sessionDuration % 60;
    [report appendFormat:@"Duração da sessão: %02d:%02d:%02d\n\n", hours, minutes, seconds];
    
    // Resumo de performance
    [report appendString:@"RESUMO DE PERFORMANCE\n"];
    [report appendString:@"-----------------\n"];
    [report appendFormat:@"RTT médio: %.1f ms (Pico: %.1f ms)\n", self.avgRtt, self.peakRtt];
    [report appendFormat:@"Perda de pacotes média: %.2f%%\n", self.avgPacketLoss];
    [report appendFormat:@"FPS médio: %.1f\n", self.avgFps];
    [report appendFormat:@"Problemas de conectividade: %d\n", self.connectivityIssuesCount];
    
    // Análise de qualidade geral
    [report appendString:@"\nANÁLISE DE QUALIDADE\n"];
    [report appendString:@"-----------------\n"];
    
    float qualityScore = [self calculateQualityScore];
    NSString *qualityRating;
    
    if (qualityScore >= 90) {
        qualityRating = @"Excelente";
    } else if (qualityScore >= 75) {
        qualityRating = @"Boa";
    } else if (qualityScore >= 60) {
        qualityRating = @"Regular";
    } else if (qualityScore >= 40) {
        qualityRating = @"Baixa";
    } else {
        qualityRating = @"Crítica";
    }
    
    [report appendFormat:@"Pontuação de qualidade: %.1f/100 (%@)\n\n", qualityScore, qualityRating];
    
    // Problemas detectados
    NSArray<NSString *> *issues = [self detectPotentialIssues];
    if (issues.count > 0) {
        [report appendString:@"PROBLEMAS DETECTADOS\n"];
        [report appendString:@"-----------------\n"];
        
        for (NSString *issue in issues) {
            [report appendFormat:@"• %@\n", issue];
        }
        [report appendString:@"\n"];
    }
    
    // Eventos recentes (últimos 10)
    [report appendString:@"EVENTOS RECENTES\n"];
    [report appendString:@"-----------------\n"];
    
    int eventsToShow = MIN(10, (int)self.events.count);
    NSArray *recentEvents = [self.events subarrayWithRange:NSMakeRange(self.events.count - eventsToShow, eventsToShow)];
    
    for (NSDictionary *event in recentEvents) {
        NSDate *timestamp = event[@"timestamp"];
        NSString *category = event[@"category"];
        NSString *type = event[@"type"];
        
        [report appendFormat:@"[%@] %@: %@\n",
         [formatter stringFromDate:timestamp],
         category,
         type];
    }
    
    // Erros críticos
    if (self.errors.count > 0) {
        [report appendString:@"\nERROS CRÍTICOS\n"];
        [report appendString:@"-----------------\n"];
        
        for (NSDictionary *error in self.errors) {
            NSDate *timestamp = error[@"timestamp"];
            NSString *message = error[@"message"];
            NSNumber *code = error[@"code"];
            
            [report appendFormat:@"[%@] [Código %@] %@\n",
             [formatter stringFromDate:timestamp],
             code,
             message];
        }
    }
    
    // Recomendações
    NSArray<NSString *> *recommendations = [self generateRecommendations];
    if (recommendations.count > 0) {
        [report appendString:@"\nRECOMENDAÇÕES\n"];
        [report appendString:@"-----------------\n"];
        
        for (NSString *recommendation in recommendations) {
            [report appendFormat:@"• %@\n", recommendation];
        }
    }
    
    [self.dataLock unlock];
    
    return report;
}

- (float)calculateQualityScore {
    // Ponderação de fatores para pontuação de qualidade
    // 100 = perfeito, 0 = inutilizável
    
    float score = 100.0;
    
    // Penalidade para RTT alto
    if (self.avgRtt > kCriticalRttThreshold) {
        score -= 40.0 * (self.avgRtt / kCriticalRttThreshold);
    } else if (self.avgRtt > kHighRttThreshold) {
        score -= 20.0 * (self.avgRtt - kHighRttThreshold) / (kCriticalRttThreshold - kHighRttThreshold);
    }
    
    // Penalidade para perda de pacotes
    if (self.avgPacketLoss > kPacketLossCriticalThreshold) {
        score -= 30.0 * (self.avgPacketLoss / kPacketLossCriticalThreshold);
    } else if (self.avgPacketLoss > kPacketLossWarningThreshold) {
        score -= 15.0 * (self.avgPacketLoss - kPacketLossWarningThreshold) /
                      (kPacketLossCriticalThreshold - kPacketLossWarningThreshold);
    }
    
    // Penalidade para baixo FPS
    float expectedFps = 30.0; // Expectativa de 30fps
    if (self.avgFps < kLowFpsThreshold) {
        score -= 25.0 * (1.0 - (self.avgFps / expectedFps));
    } else if (self.avgFps < expectedFps) {
        score -= 10.0 * (1.0 - (self.avgFps / expectedFps));
    }
    
    // Penalidade para problemas de conectividade
    score -= MIN(25.0, 5.0 * self.connectivityIssuesCount);
    
    // Garantir que a pontuação esteja entre 0 e 100
    return MAX(0.0, MIN(100.0, score));
}

- (NSArray<NSString *> *)detectPotentialIssues {
    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    
    // Problemas de latência
    if (self.avgRtt > kCriticalRttThreshold) {
        [issues addObject:[NSString stringWithFormat:@"Latência extremamente alta (%.1f ms) pode indicar problemas graves de rede.", self.avgRtt]];
    } else if (self.avgRtt > kHighRttThreshold) {
        [issues addObject:[NSString stringWithFormat:@"Latência elevada (%.1f ms) pode causar atrasos perceptíveis.", self.avgRtt]];
    }
    
    // Problemas de perda de pacotes
    if (self.avgPacketLoss > kPacketLossCriticalThreshold) {
        [issues addObject:[NSString stringWithFormat:@"Perda de pacotes crítica (%.1f%%) está causando problemas de qualidade.", self.avgPacketLoss]];
    } else if (self.avgPacketLoss > kPacketLossWarningThreshold) {
        [issues addObject:[NSString stringWithFormat:@"Perda de pacotes elevada (%.1f%%) pode afetar a qualidade.", self.avgPacketLoss]];
    }
    
    // Problemas de framerate
    if (self.avgFps < kLowFpsThreshold) {
        [issues addObject:[NSString stringWithFormat:@"Taxa de quadros muito baixa (%.1f fps) está causando vídeo truncado.", self.avgFps]];
    } else if (self.avgFps < 20.0) {
        [issues addObject:[NSString stringWithFormat:@"Taxa de quadros abaixo do ideal (%.1f fps) pode causar vídeo não fluido.", self.avgFps]];
    }
    
    // Problemas de conectividade
    if (self.connectivityIssuesCount > 3) {
        [issues addObject:[NSString stringWithFormat:@"Múltiplas desconexões (%d) indicam uma rede instável.", self.connectivityIssuesCount]];
    }
    
    // Problemas de hardware (exemplos)
    if (self.avgFps < 15.0 && self.avgRtt < kHighRttThreshold && self.avgPacketLoss < kPacketLossWarningThreshold) {
        [issues addObject:@"Baixo desempenho apesar de boa conexão pode indicar problemas de hardware ou sobrecarga do dispositivo."];
    }
    
    return issues;
}

- (NSArray<NSString *> *)generateRecommendations {
    NSMutableArray<NSString *> *recommendations = [NSMutableArray array];
    NSArray<NSString *> *issues = [self detectPotentialIssues];
    
    // Baseado nos problemas detectados, fazer recomendações específicas
    BOOL hasNetworkIssues = NO;
    BOOL hasPerformanceIssues = NO;
    BOOL hasConnectivityIssues = NO;
    
    for (NSString *issue in issues) {
        if ([issue containsString:@"latência"] || [issue containsString:@"perda de pacotes"]) {
            hasNetworkIssues = YES;
        }
        if ([issue containsString:@"taxa de quadros"] || [issue containsString:@"desempenho"]) {
            hasPerformanceIssues = YES;
        }
        if ([issue containsString:@"desconexões"] || [issue containsString:@"instável"]) {
            hasConnectivityIssues = YES;
        }
    }
    
    // Recomendações para problemas de rede
    if (hasNetworkIssues) {
        if (self.avgRtt > kCriticalRttThreshold || self.avgPacketLoss > kPacketLossCriticalThreshold) {
            [recommendations addObject:@"Utilize uma conexão de rede mais estável, preferencialmente Wi-Fi 5GHz ou Ethernet."];
            [recommendations addObject:@"Verifique se outros dispositivos na rede estão consumindo largura de banda excessiva."];
        } else {
            [recommendations addObject:@"Aproxime-se do roteador Wi-Fi para melhorar a qualidade do sinal."];
            [recommendations addObject:@"Tente reduzir a resolução do vídeo para economizar largura de banda."];
        }
    }
    
    // Recomendações para problemas de performance
    if (hasPerformanceIssues) {
        [recommendations addObject:@"Feche aplicativos em segundo plano para liberar recursos do dispositivo."];
        [recommendations addObject:@"Verifique se o dispositivo não está superaquecendo, o que pode causar throttling de CPU."];
        
        if (self.avgFps < 15.0) {
            [recommendations addObject:@"Reduza a resolução ou qualidade do vídeo nas configurações para melhorar a fluidez."];
        }
    }
    
    // Recomendações para problemas de conectividade
    if (hasConnectivityIssues) {
        [recommendations addObject:@"Verifique se o servidor WebRTC está online e acessível."];
        [recommendations addObject:@"Reinicie o roteador Wi-Fi para resolver possíveis problemas de conexão."];
        [recommendations addObject:@"Verifique se o firewall não está bloqueando a conexão WebRTC."];
    }
    
    // Recomendações gerais sempre úteis
    if (recommendations.count == 0) {
        [recommendations addObject:@"A conexão está funcionando bem. Para melhor desempenho, sempre utilize rede Wi-Fi em vez de dados móveis."];
    } else {
        [recommendations addObject:@"Considere reiniciar o aplicativo após fazer alterações para garantir efeito completo."];
    }
    
    return recommendations;
}

- (NSDictionary *)getPerformanceStats {
    [self.dataLock lock];
    
    // Criar dicionário com as principais métricas de desempenho
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    // Dados da sessão
    [stats setObject:self.startTime forKey:@"sessionStartTime"];
    [stats setObject:@([[NSDate date] timeIntervalSinceDate:self.startTime]) forKey:@"sessionDuration"];
    [stats setObject:@(self.isMonitoring) forKey:@"isMonitoring"];
    
    // Métricas de rede
    [stats setObject:@(self.avgRtt) forKey:@"avgRtt"];
    [stats setObject:@(self.peakRtt) forKey:@"peakRtt"];
    [stats setObject:@(self.avgPacketLoss) forKey:@"avgPacketLoss"];
    
    // Métricas de vídeo
    [stats setObject:@(self.avgFps) forKey:@"avgFps"];
    
    // Última resolução conhecida
    if (self.videoMetricsHistory.count > 0) {
        NSDictionary *lastVideo = [self.videoMetricsHistory lastObject];
        NSValue *resolutionValue = lastVideo[@"resolution"];
        CGSize resolution = [resolutionValue CGSizeValue];
        
        [stats setObject:@{
            @"width": @(resolution.width),
            @"height": @(resolution.height)
        } forKey:@"resolution"];
        
        if (lastVideo[@"bitrate"]) {
            [stats setObject:lastVideo[@"bitrate"] forKey:@"bitrate"];
        }
    }
    
    // Estatísticas de problemas
    [stats setObject:@(self.connectivityIssuesCount) forKey:@"connectivityIssues"];
    [stats setObject:@(self.errors.count) forKey:@"errorCount"];
    
    // Qualidade geral
    float qualityScore = [self calculateQualityScore];
    [stats setObject:@(qualityScore) forKey:@"qualityScore"];
    
    // Última atualização
    [stats setObject:[NSDate date] forKey:@"lastUpdated"];
    
    [self.dataLock unlock];
    
    return stats;
}

- (NSString *)saveDiagnosticReport {
    NSString *report = [self generateDiagnosticReport];
    
    // Criar nome de arquivo com timestamp
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    
    NSString *filename = [NSString stringWithFormat:@"webrtc_diagnostics_%@.txt", timestamp];
    NSString *filePath = [self.diagnosticsDirectory stringByAppendingPathComponent:filename];
    
    // Salvar o relatório no arquivo
    NSError *error = nil;
    [report writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    
    if (error) {
        writeErrorLog(@"[WebRTCDiagnostics] Erro ao salvar relatório: %@", error);
        return nil;
    }
    
    writeLog(@"[WebRTCDiagnostics] Relatório de diagnóstico salvo em: %@", filePath);
    return filePath;
}

- (void)clearDiagnosticData {
    [self.dataLock lock];
    
    // Limpar todos os arrays e dicionários
    [self.events removeAllObjects];
    [self.currentMetrics removeAllObjects];
    [self.videoMetricsHistory removeAllObjects];
    [self.networkMetricsHistory removeAllObjects];
    [self.errors removeAllObjects];
    
    // Resetar contadores e médias
    self.avgRtt = 0.0;
    self.avgPacketLoss = 0.0;
    self.avgFps = 0.0;
    self.peakRtt = 0.0;
    self.connectivityIssuesCount = 0;
    self.framesDropped = 0;
    
    // Reiniciar o timestamp de início
    self.startTime = [NSDate date];
    
    writeLog(@"[WebRTCDiagnostics] Dados de diagnóstico limpos");
    
    [self.dataLock unlock];
}

- (void)sendDiagnosticData:(void(^)(BOOL success, NSError *error))completionHandler {
    // Esta é uma implementação simulada que na vida real seria uma chamada de API
    // para enviar dados de telemetria para análise
    
    // Primeiro, gerar dados JSON com estatísticas
    NSDictionary *statsData = [self getPerformanceStats];
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:statsData options:0 error:&jsonError];
    
    if (jsonError) {
        writeErrorLog(@"[WebRTCDiagnostics] Erro ao serializar dados de diagnóstico: %@", jsonError);
        if (completionHandler) {
            completionHandler(NO, jsonError);
        }
        return;
    }
    
    // Simulação de envio bem-sucedido
    writeLog(@"[WebRTCDiagnostics] Dados de diagnóstico preparados para envio: %ld bytes", (long)[jsonData length]);
    
    // Atraso simulado para API
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Considerar 95% de chance de sucesso
        float randomValue = ((float)arc4random() / UINT32_MAX);
        
        if (randomValue <= 0.95) {
            writeLog(@"[WebRTCDiagnostics] Dados de diagnóstico enviados com sucesso");
            if (completionHandler) {
                completionHandler(YES, nil);
            }
        } else {
            NSError *simulatedError = [NSError errorWithDomain:@"com.webrtctweak.diagnostics"
                                                          code:500
                                                      userInfo:@{NSLocalizedDescriptionKey: @"Erro de rede simulado"}];
            writeErrorLog(@"[WebRTCDiagnostics] Falha ao enviar dados de diagnóstico: %@", simulatedError);
            if (completionHandler) {
                completionHandler(NO, simulatedError);
            }
        }
    });
}

@end
