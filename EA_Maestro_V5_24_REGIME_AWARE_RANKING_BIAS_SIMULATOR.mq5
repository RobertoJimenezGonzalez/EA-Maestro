//+------------------------------------------------------------------+
//| EA_Maestro_V5_24_REGIME_AWARE_RANKING_BIAS_SIMULATOR.mq5              |
//| Sistema de Trading — EA Maestro V5.10                              |
//| Gold BUY Catastrophe Shield — V5.4 preserved                           |
//|                                                                  |
//| OBJETIVO                                                         |
//| - EA operativo experimental                                       |
//| - Hace entradas reales en tester/demo                             |
//| - No depende de CSV externo                                       |
//| - Usa estado secuencial por activo                                |
//| - Entra solo tras: COMPRESION -> EXPANSION -> ACEPTACION          |
//| - Gobernanza conservadora tipo fondeada                           |
//| - Anti-hedge absoluto por símbolo                                 |
//| - Máximo 1 trade por símbolo por día                              |
//| - Máximo 3 trades totales por día                                 |
//| - Bloqueo preventivo DD acumulado en 4.00%                        |
//| - Auditoría completa de decisiones, entradas y cierres            |
//|                                                                  |
//| NOTA                                                            |
//| Este archivo es V5.1 experimental, construido directamente sobre V4.9. Conserva el Asset Regime Router ganador y añade protección controlada de beneficios sin asfixiar US500 ni XAUUSD. Validar siempre en tester.       |
//+------------------------------------------------------------------+
#property strict
//#property version   "5.13B"
#property description "EA Maestro V5.19 Trade Lifecycle Protector - V5.14B base + V5.18 learning + conservative post-1R protection"

#include <Trade/Trade.mqh>
CTrade trade;

// ==================================================================
// INPUTS
// ==================================================================
input string InpRunId                  = "V5_24_REGIME_AWARE_RANKING_BIAS_SIMULATOR_001";
input string InpOutputCSV              = "V5_24_REGIME_AWARE_RANKING_BIAS_SIMULATOR.csv";

input string InpSymbolsCSV             = "XAUUSD,US500.cash,GER40.cash,US100.cash";

input ENUM_TIMEFRAMES InpMicroTF       = PERIOD_M5;
input ENUM_TIMEFRAMES InpDecisionTF    = PERIOD_M15;
input ENUM_TIMEFRAMES InpContextTF     = PERIOD_H1;

input int    InpLookbackBars           = 20;
input int    InpATRPeriod              = 14;
input int    InpFastMAPeriod           = 20;
input int    InpSlowMAPeriod           = 50;
input int    InpADXPeriod              = 14;

// Trading
input bool   EnableRealEntries         = true;
input ulong  MagicNumber               = 250250;
input double RiskPerTradePercent       = 0.14;
input double HardMaxLossPerTradePercent = 0.35;   // broker-calculated hard cap per position

// Equity protection and selector learning
input bool   EnableEquityProfitLock    = true;
input double ProfitLockActivationMoney = 5000.0;
input double ProfitLockRatio           = 0.55;   // locks 55% of accumulated peak profit
input double ProfitGivebackPauseMoney  = 3500.0; // pause if equity gives back this much from peak
input int    EquityLockPauseHours       = 24;     // V4.0: circuit-breaker pause, not permanent death
input bool   EquityLockRearmAfterPause  = true;   // reset peak/floor after the pause so the EA can trade again

// V4.3 — Verified Curve Defense.
// Basado en el diagnóstico real: V4.0 generó beneficio pero devolvió demasiado;
// V4.1/V4.2 asfixiaron el motor con demasiada calidad mínima.
// Esta defensa NO cambia la lógica de entrada base: reduce exposición y exige un poco más
// solo después de una devolución real desde máximos.
input bool   EnableProfitDefenseEngine  = true;
input double ProfitDefenseActivationMoney = 5000.0;
input double ProfitDefenseSoftGivebackMoney = 2500.0;
input double ProfitDefenseHardGivebackMoney = 5000.0;
input double ProfitDefenseRiskFactorSoft = 1.00;  // V5.1: no tocar lotaje/riesgo base por defecto
input double ProfitDefenseRiskFactorHard = 1.00;  // V5.1: protección por calidad, no por reducción de lote
input double ProfitDefenseQualityAddSoft = 0.5;   // V5.1: suave, evita asfixia tipo V5.0
input double ProfitDefenseQualityAddHard = 1.0;   // V5.1: defensiva, pero deja respirar al motor
input bool   DisableContextBoostInDefense = true;

// V4.4 — Trade Survival Intelligence.
// Objetivo: reducir entradas que mueren rápido sin asfixiar el motor rentable de V4.3.
input bool   EnableTradeSurvivalEngine  = true;
input double TradeSurvivalMinScore      = 62.0;
input double TradeSurvivalMinScoreIndex = 64.0;
input double TradeSurvivalMinScoreUS500 = 68.0;
input double TradeSurvivalDefenseAddSoft = 4.0;
input double TradeSurvivalDefenseAddHard = 8.0;
input double TradeSurvivalConsecutiveLossAdd = 3.0;
input double TradeSurvivalMaxImmediateDeathRisk = 66.0;
input double TradeSurvivalMaxImmediateDeathRiskIndex = 62.0;
input double TradeSurvivalMaxImmediateDeathRiskUS500 = 58.0;
input bool   TradeSurvivalAuditBlocks   = true;

// V4.5 — Asset Role Survival Engine.
// Diagnóstico verificado V4.4: XAUUSD sostiene la curva; índices erosionan.
// No se elimina el multiactivo, pero cada activo recibe un rol distinto.
input bool   EnableAssetRoleEngine      = true;
input double TradeSurvivalMinScoreGold  = 58.0;
input double TradeSurvivalMaxImmediateDeathRiskGold = 72.0;
input double AssetRoleGoldBonus         = 4.0;
input double AssetRoleIndexPenalty      = 3.0;
input double AssetRoleUS500Penalty      = 5.0;
input double IndexAPlusMinSurvival      = 74.0;
input double IndexAPlusMinFollow        = 0.58;
input double IndexAPlusMinAcceptance    = 0.72;
input double IndexAPlusMinCleanContext  = 68.0;
input double IndexAPlusMaxWickRisk      = 0.38;
input double IndexAPlusMaxOppAcceptanceGap = 0.08;
input bool   US500OnlyAPlus             = false;

// V4.6: cada activo tiene idioma propio. El gobierno global sigue igual,
// pero la lectura de entrada deja de usar una regla única para todos.
input bool   EnableAssetSpecificEngine     = true;
input double SelectorQualityGold           = 70.0;
input double SelectorQualityUS500          = 68.0;
input double SelectorQualityUS100          = 74.0;
input double SelectorQualityGER40          = 78.0;

input double SurvivalGold                  = 58.0;
input double SurvivalUS500                 = 60.0;
input double SurvivalUS100                 = 68.0;
input double SurvivalGER40                 = 72.0;

input double US500_MinFollow               = 0.48;
input double US500_MinAcceptance           = 0.58;
input double US500_MinCleanContext         = 61.0;
input double US500_MaxWickRisk             = 0.52;
input double US500_MaxOppAcceptanceGap     = 0.10;
input double US500_MinAlignment            = 0.58;

input double US100_MinFollow               = 0.56;
input double US100_MinAcceptance           = 0.64;
input double US100_MinCleanContext         = 64.0;
input double US100_MaxWickRisk             = 0.58;
input double US100_MinStrength             = 0.60;

input double GER40_MinFollow               = 0.56;
input double GER40_MinAcceptance           = 0.64;
input double GER40_MinCleanContext         = 68.0;
input double GER40_MaxWickRisk             = 0.42;
input double GER40_MinSessionActivity      = 0.55;

// V4.7 — Asset Adaptive Timing Engine.
// No cambia lotaje, riesgo ni gobierno FTMO. Solo ajusta cuándo cada activo puede entrar.
input bool   EnableAssetAdaptiveTimingEngine = true;
input double Gold_MaxLateExpansion           = 0.88;
input double Gold_MinFreshFollow             = 0.54;
input double Gold_MaxTimingWickRisk          = 0.56;
input double US500_MinRangeEfficiency        = 0.24;
input double US500_MaxTimingWickRisk         = 0.46;
input double US500_MinPullbackAcceptance     = 0.68;
input double US100_MinMomentumExpansion      = 0.66;
input double US100_MaxTimingConflict         = 0.34;
input double GER40_MinTimingStrength         = 0.58;
input double GER40_MaxTimingConflict         = 0.24;
input int    GER40_TimingStartHour           = 8;
input int    GER40_TimingEndHour             = 12;

// V4.8 — Market Read Confirmation Engine.
// Capa previa: cada activo debe demostrar que está en un régimen operable antes del timing.
input bool   EnableMarketReadConfirmationEngine = true;
input double MRCE_MinGoldRegimeScore        = 66.0;
input double MRCE_MinUS500RegimeScore       = 70.0;
input double MRCE_MinUS100RegimeScore       = 72.0;
input double MRCE_MinGER40RegimeScore       = 78.0;
input double MRCE_US500_MinTradeRangeEff    = 0.26;
input double MRCE_US500_MinFollow           = 0.56;
input double MRCE_US500_MaxWick             = 0.44;
input double MRCE_US500_MaxConflictGap      = 0.06;
input double MRCE_US500_MinSessionActivity  = 0.24;
input double MRCE_Gold_MaxExhaustionDecay   = 0.58;
input double MRCE_Gold_MinLifeWhenExtended  = 76.0;
input double MRCE_US100_MinMomentumScore    = 74.0;
input double MRCE_GER40_MinSessionActivity  = 0.34;
input double MRCE_GER40_MaxConflictGap      = 0.04;

// V4.9 — Asset Regime Router Engine.
// No cambia lotaje, riesgo ni FTMO. Decide si el activo está en un régimen operable antes de permitir timing.
input bool   EnableAssetRegimeRouterEngine = true;
input double ARRE_GlobalMaxWickRisk        = 0.62;
input double ARRE_GlobalMinFollow          = 0.42;
input double ARRE_GlobalMaxConflictGap     = 0.18;

input double ARRE_US500_MinTrendFollow     = 0.50;
input double ARRE_US500_MinPullbackFollow  = 0.44;
input double ARRE_US500_MinAcceptance      = 0.58;
input double ARRE_US500_MinRangeEfficiency = 0.16;
input double ARRE_US500_MaxWick            = 0.52;
input double ARRE_US500_MaxConflictGap     = 0.12;

input double ARRE_US100_MinMomentum        = 0.66;
input double ARRE_US100_MinTrendStrength   = 0.62;
input double ARRE_US100_MaxConflictGap     = 0.10;

input double ARRE_Gold_MaxExhaustion       = 0.66;
input double ARRE_Gold_MaxWick             = 0.64;
input double ARRE_Gold_MaxConflictGap      = 0.16;

input double ARRE_GER40_MinTrendStrength   = 0.66;
input double ARRE_GER40_MaxWick            = 0.40;
input double ARRE_GER40_MaxConflictGap     = 0.05;

// V5.1 — Controlled Profit Protection.
// Conserva V4.9. Solo modula entradas cuando ya existe beneficio y hay devolución desde máximo.
input bool   EnableControlledProfitProtection = true;
input double CPP_ActivationProfitMoney        = 5000.0;
input double CPP_ProtectDrawdownPctFromPeak   = 1.50;
input double CPP_DefensiveDrawdownPctFromPeak = 3.00;
input double CPP_ProtectContinuityAdd         = 0.06;
input double CPP_DefensiveQualityAdd          = 3.0;
input bool   CPP_BlockGER40InDefensive        = true;
input bool   CPP_KeepUS500Alive               = true;

// V5.3 — Internal Asset Engines + Global Opportunity Ranking.
// Cada activo analiza con su propio motor interno. Todos compiten por el capital disponible.
// La gobernanza FTMO sigue siendo global; la lectura y ejecución se adaptan al activo.
input bool   EnableGlobalOpportunityRanking = true;
input int    MaxCandidatesPerCycle          = 16;
input double Ranking_MinScoreGold           = 67.0;
input double Ranking_MinScoreUS500          = 66.0;
input double Ranking_MinScoreUS100          = 69.0;
input double Ranking_MinScoreGER40          = 76.0;
input double Ranking_GoldContinuityBonus    = 2.0;
input double Ranking_USIndexCleanBonus      = 3.0;
input double Ranking_RecentLossPenalty      = 3.0;
input bool   Ranking_AuditLosingCandidates  = true;

// V5.4 — Asset Engine Ranking Refinement.
// Refinamiento quirúrgico basado en CSV V5.3. No sustituye la arquitectura ganadora;
// penaliza solo los patrones horarios/direccionales que demostraron pérdida.
input bool   EnableV54SurgicalRankingRefinement = true;
input double V54_GoldBuyBadHourPenalty           = 7.0;
input double V54_GoldBuyBadHourExceptionalScore  = 80.0;
input double V54_GoldSellPreserveBonus           = 2.5;
input double V54_US500BuyHour13Penalty           = 6.0;
input double V54_US500SellPenalty                = 8.0;
input double V54_GER40ObserverPenalty            = 12.0;
input bool   V54_BlockGER40UnlessExceptional     = true;
input double V54_GER40ExceptionalScore           = 88.0;

// V5.10 — Gold BUY Catastrophe Shield.
// Base real: V5.4. No reconstruye XAUUSD BUY, no toca XAUUSD SELL,
// no cambia el ranking global ni usa bloqueos por horario nuevos.
// Solo elimina compras de oro con rechazo extremo simultáneo.
input bool   EnableV510GoldBuyCatastropheShield  = true;
input double V510_GoldBuyMaxWickCatastrophe      = 0.74;
input double V510_GoldBuyMaxRejectionCatastrophe = 0.64;
input double V510_GoldBuyMinAcceptanceCatastrophe= 0.44;
input double V510_GoldBuyMinFollowCatastrophe    = 0.48;
input double V510_GoldBuyMaxRangeEffCatastrophe  = 0.12;

// V5.18 — Learning Engine.
// Capa de aprendizaje: observa, registra lectura de entrada y mide resultado real del trade.
// NO bloquea, NO modifica entradas, NO modifica SL, TP ni lotaje.
// Objetivo: descubrir por activo qué condiciones reales preceden ganancias y pérdidas.
input bool   EnableV516MarketReaderGatekeeper = true;   // nombre legado; en V5.17 funciona como observer
input bool   V516_AuditGatekeeperAllows       = true;
input double V516_MinScoreGold                = 64.0;
input double V516_MinScoreUS500               = 63.0;
input double V516_MinScoreUS100               = 66.0;
input double V516_MinScoreGER40               = 88.0;
input double V516_MinScoreDefault             = 66.0;
input double V516_MinSpreadQuality            = 0.35;
input double V516_MinLiquidityQuality         = 0.35;
input double V516_MaxConflictGold             = 0.42;
input double V516_MaxConflictUS500            = 0.40;
input double V516_MaxConflictUS100            = 0.38;
input double V516_MaxConflictGER40            = 0.26;
input double V516_MaxFalseExpansionGold       = 52.0;
input double V516_MaxFalseExpansionUS500      = 50.0;
input double V516_MaxFalseExpansionUS100      = 48.0;
input double V516_MaxFalseExpansionGER40      = 38.0;
input double V516_MaxImmediateDeathGold       = 74.0;
input double V516_MaxImmediateDeathUS500      = 66.0;
input double V516_MaxImmediateDeathUS100      = 64.0;
input double V516_MaxImmediateDeathGER40      = 58.0;

// V5.18 — Learning Engine controls.
input bool   EnableV518LearningEngine       = true;
input bool   V518_AuditLearningEntry        = true;
input bool   V518_AuditLearningClose        = true;
input bool   V518_TrackMFE_MAE              = true;
input double V518_BigWinR                   = 1.00;
input double V518_SmallWinR                 = 0.20;
input double V518_BigLossR                  = -0.80;

// V5.19 — Trade Lifecycle Protector.
// V5.20: queda desactivado por defecto. La versión actual observa el ciclo de vida sin modificar SL/TP/lote.
input bool   EnableV519LifecycleProtector = false;  // V5.20: desactivado; solo observación
input double V519_ProtectTriggerR         = 1.00;   // cuando el trade alcanza +1R
input double V519_ProtectLockR            = -0.20;  // protección suave: máximo retroceso permitido ≈ -0.20R
input bool   V519_ProtectOnlyOnce         = true;
input bool   V519_AuditProtection         = true;
input int    V519_MinBarsAfterEntry       = 0;      // 0 = actuar en cuanto haya vida real

// V5.20 — Lifecycle Observer Advanced.
// NO bloquea, NO protege, NO modifica SL/TP/lote. Solo registra hit-levels y retrocesos.
input bool   EnableV520LifecycleObserver   = true;
input bool   V520_AuditHitLevels           = true;
input double V520_Level05R                 = 0.50;
input double V520_Level1R                  = 1.00;
input double V520_Level2R                  = 2.00;
input double V520_Level3R                  = 3.00;

// V5.22 — Market Regime Intelligence Observer.
// Observador puro: NO bloquea, NO protege, NO modifica SL/TP/lote.
// Objetivo: aprender qué régimen real favorece a cada activo.
input bool   EnableV522MarketRegimeObserver = true;
input bool   V522_AuditRegimeOnEntry        = true;
input int    V522_RegimeLookbackBars        = 34;
input double V522_DirtyTrendMinEfficiency   = 0.18;
input double V522_CleanTrendMinEfficiency   = 0.32;
input double V522_ChopHigh                  = 0.62;

// V5.24 — Regime-Aware Ranking Bias SIMULATOR.
// Observador puro: NO cambia selección real, NO bloquea, NO toca SL/TP/lote.
// Solo calcula qué habría preferido un ranking por régimen.
input bool   EnableV524RankingBiasSimulator = true;
input bool   V524_AuditSimulatedRanking     = true;
input double V524_XAU_TrendDirtyBonus       = 20.0;
input double V524_XAU_TrendCleanBonus       = 10.0;
input double V524_XAU_ChopPenalty           = -15.0;
input double V524_US500_TrendCleanBonus     = 20.0;
input double V524_US500_TrendDirtyPenalty   = -5.0;
input double V524_US500_RangePenalty        = -10.0;
input double V524_US500_ChopPenalty         = -20.0;
input double V524_US100_ExpansionBonus      = 25.0;
input double V524_US100_TrendCleanBonus     = 10.0;
input double V524_US100_TrendDirtyPenalty   = -10.0;
input double V524_US100_RangePenalty        = -15.0;
input double V524_US100_ChopPenalty         = -25.0;
input double V524_GlobalChopPenalty         = -10.0;


// Market Understanding Engine V4.0
input bool   UseMarketUnderstandingEngine = true;
input double MUE_MinSurvivalScore       = 72.0;
input double MUE_MaxFalseExpansionRisk  = 46.0;
input double MUE_MinCleanContext        = 62.0;
input double MUE_MinImpulseFreshness    = 54.0;
input double MUE_MaxDecisionConflict    = 0.32;
input bool   EnableAdaptiveCooldown    = true;
input int    MaxConsecutiveLossesAsset = 3;
input int    CooldownBarsAfterLosses   = 96;
input double MinSelectorQuality        = 72.0;
input double MinSelectorQualityIndex   = 74.0;
input double MinSelectorQualityUS500   = 78.0;
input double MinLot                    = 0.01;
input double MaxLot                    = 120.00;  // global technical cap
input double MaxLotXAU                 = 4.00;
input double MaxLotUS500               = 120.00;
input double MaxLotGER40               = 80.00;
input double MaxLotUS100               = 80.00;
input double MaxLotDefault             = 30.00;

input bool   UseContextLotBoost        = true;
input double MaxContextLotBoost        = 1.80;
input double MinContextScoreForBoost   = 76.0;
input double SL_ATR_Multiplier         = 1.15;
input double TP_ATR_Multiplier         = 5.60;  // V5.14B: base TP +12%, SL unchanged
input int    MaxHoldBars               = 96;
input int    SlippagePoints            = 20;

// Professional asymmetric exit management
input double MinRewardRiskRatio        = 3.00;
input double IdealRewardRiskRatio      = 5.60;  // V5.14B: base TP +12%, US500/US100 use +14%, SL unchanged
input double BreakEvenAtR              = 1.50;
input double BreakEvenLockR            = 0.10;
input double TrailStartR               = 3.00;
input double TrailATRMultiplier        = 1.20;
input double WeaknessExitMinR          = 4.00;
input double ExpansionDecayMax         = 0.42;
input double FollowDecayMax            = 0.45;
input double WickExitRiskMin           = 0.62;
input double MinExpectedProfitMoney    = 80.0;
input bool   UseBreakEven              = false;
input bool   UseDynamicTrailing        = false;   // disabled in V3.0; structural trailing replaces it
input bool   UseWeaknessExit           = true;
input bool   AllowStopModification      = false;  // V3.3: no BE, no trailing, no profit cap
input bool   UseTrailingTotalDDFromPeak = false;  // false = accumulated DD from initial equity

// Expansion lifecycle management
input bool   UseExpansionLifecycleExit  = true;
input bool   UseStructuralTrailing      = false;
input int    StructuralSwingLookback    = 6;
input double StructuralBufferATR        = 0.25;
input double StructuralTrailStartR      = 2.80;
input double ProtectAt2R_LockR          = 0.50;
input double ProtectAt3R_LockR          = 1.30;
input double ProtectAt5R_LockR          = 2.50;
input bool   NoTrailingBeforeMature     = true;
input double LifecycleProtectAtR        = 3.00;
input double LifecycleMatureAtR         = 3.50;
input double LifecycleExhaustAtR        = 4.00;
input double LifecycleDecayExitScore    = 62.0;
input double LifecycleMatureTrailATR    = 0.95;
input int    StagnationBarsAfterEntry   = 48;
input double StagnationMinR             = -0.75;

// Prop firm governance
input double MaxDailyDDPercent         = 0.80;
input double HardDailyDDPercent        = 0.90;
input double PreventiveTotalDDPercent  = 4.00;
input double HardTotalDDPercent        = 4.50;
input int    MaxOpenPositions          = 2;
input int    MaxTradesPerDay           = 3;
input int    MaxTradesPerSymbolPerDay  = 1;
input bool   AntiHedgePerSymbol        = true;
input double MaxMarginUsagePercent     = 28.0;
input double MaxSpreadToATRPercent     = 16.0;

// Transition logic
input int    CompressionExpireBars     = 10;
input int    ExpansionExpireBars       = 9;
input double BaseCompressionMin        = 0.58;
input double BaseExpansionMin          = 0.66;
input double BaseAcceptanceMin         = 0.62;
input double BaseFollowMin             = 0.57;
input double BaseWickRiskMax           = 0.42;
input double BaseDirectionAlignMin     = 0.66;
input double BaseScoreMin              = 70.0;

// Asset behavior reader
input bool   UseAssetBehaviorReader    = true;
input double IndexLateAcceptanceBonus  = 5.0;
input double IndexLiquidityMin         = 0.38;
input double GoldLiquidityMin          = 0.55;
input double IndexFollowSoftFloor      = 0.46;
input double GoldFollowSoftFloor       = 0.52;

// Score weights
input double W_Direction               = 15.0;
input double W_Strength                = 20.0;
input double W_Expansion               = 20.0;
input double W_Acceptance              = 20.0;
input double W_VolatilityRoom          = 10.0;
input double W_Liquidity               = 10.0;
input double W_Structure               = 10.0;
input double W_Session                 = 5.0;
input double W_TrapPenalty             = 20.0;

// ==================================================================
// ENUMS / STRUCTS
// ==================================================================
enum TransitionState
{
   TS_NORMAL = 0,
   TS_COMPRESSION = 1,
   TS_EXPANSION = 2,
   TS_ACCEPTANCE = 3
};

struct SymbolState
{
   string symbol;
   datetime last_bar_time;

   int h_atr_decision;
   int h_ema_fast_micro;
   int h_ema_fast_decision;
   int h_ema_fast_context;
   int h_ema_slow_micro;
   int h_ema_slow_decision;
   int h_ema_slow_context;
   int h_adx_decision;

   TransitionState state;
   int state_direction;
   int state_age_bars;
   datetime compression_time;
   datetime expansion_time;

   int trades_today;
   int consecutive_losses;
   datetime cooldown_until;
};

struct V518TradeMemory
{
   bool active;
   ulong ticket;
   string symbol;
   int direction;
   datetime open_time;
   double entry_price;
   double sl;
   double tp;
   double volume;
   double entry_reader_score;
   double entry_required_score;
   double entry_conflict;
   double entry_false_expansion;
   double entry_immediate_death;
   double mfe_r;
   double mae_r;
   string entry_reader_reason;
   bool v519_lifecycle_protected;
   bool v520_hit_05r;
   bool v520_hit_1r;
   bool v520_hit_2r;
   bool v520_hit_3r;
   double v520_max_pullback_after_1r;
};

V518TradeMemory g_v518_trades[];

// ==================================================================
// ASSET REGIME ROUTER ENGINE V4.9 TYPES
// ==================================================================
enum MarketRegimeType
{
   REGIME_TREND=0,
   REGIME_PULLBACK=1,
   REGIME_RANGE=2,
   REGIME_EXPANSION=3,
   REGIME_UNDEFINED=4
};

string MarketRegimeName(MarketRegimeType r)
{
   if(r==REGIME_TREND) return "TREND";
   if(r==REGIME_PULLBACK) return "PULLBACK";
   if(r==REGIME_RANGE) return "RANGE";
   if(r==REGIME_EXPANSION) return "EXPANSION";
   return "UNDEFINED";
}

// V5.1 Controlled Profit Protection states.
enum ProfitProtectionState
{
   CPP_STATE_NORMAL=0,
   CPP_STATE_PROTECT=1,
   CPP_STATE_DEFENSIVE=2
};

string ProfitProtectionStateName(ProfitProtectionState s)
{
   if(s==CPP_STATE_PROTECT) return "PROTECT";
   if(s==CPP_STATE_DEFENSIVE) return "DEFENSIVE";
   return "NORMAL";
}

struct MarketContext
{
   string symbol;
   datetime signal_time;
   int hour_server;
   int dow;
   string session_label;

   double signal_price;
   double spread_points;

   int dir_m5;
   int dir_m15;
   int dir_h1;

   double direction_alignment_buy;
   double direction_alignment_sell;
   double ema_slope_buy;
   double ema_slope_sell;
   double structure_direction_buy;
   double structure_direction_sell;

   double adx_score;
   double roc_buy;
   double roc_sell;
   double candle_power_buy;
   double candle_power_sell;
   double strength_buy;
   double strength_sell;

   double expansion_buy;
   double expansion_sell;
   double follow_buy;
   double follow_sell;
   double range_efficiency;

   double acceptance_buy;
   double acceptance_sell;
   double rejection_buy;
   double rejection_sell;
   double wick_risk_buy;
   double wick_risk_sell;

   double atr_now;
   double volatility_room_buy;
   double volatility_room_sell;
   double compression_score;

   double spread_quality;
   double liquidity_quality;

   double fibo_level;
   double fibo_zone_score;
   double swing_position_buy;
   double swing_position_sell;

   double session_activity_score;

   double score_buy;
   double score_sell;
   string regime_buy;
   string regime_sell;

   // V5.22 — Market Regime Intelligence Observer fields
   double v522_efficiency_ratio;
   double v522_choppiness;
   double v522_trend_slope_buy;
   double v522_trend_slope_sell;
   double v522_atr_regime;
   double v522_compression_expansion;
   double v522_dirty_trend_buy;
   double v522_dirty_trend_sell;
   double v522_clean_trend_buy;
   double v522_clean_trend_sell;
   string v522_regime_buy;
   string v522_regime_sell;
};

struct DriverThresholds
{
   double compression_min;
   double expansion_min;
   double acceptance_min;
   double follow_min;
   double wick_max;
   double direction_align_min;
   double score_min;
   int start_hour;
   int end_hour;
};

struct AssetCandidate
{
   bool active;
   int idx;
   MarketContext ctx;
   int direction;
   double score;
   string reason;
};


// ==================================================================
// GLOBALS
// ==================================================================
SymbolState g_states[];
int g_file = INVALID_HANDLE;
int g_rows_written = 0;

double g_initial_equity = 0.0;
double g_day_start_equity = 0.0;
double g_peak_equity = 0.0;
double g_equity_lock_floor = 0.0;
datetime g_equity_lock_pause_until = 0;
double g_max_balance_seen = 0.0;
int g_day_of_year = -1;
int g_total_trades_today = 0;
AssetCandidate g_candidates[];
int g_candidate_count = 0;

// ==================================================================
// BASIC UTILITIES
// ==================================================================
string Trim(string s){ StringTrimLeft(s); StringTrimRight(s); return s; }
double Clamp01(double v){ if(v<0.0) return 0.0; if(v>1.0) return 1.0; return v; }
double SafeDiv(double a,double b,double fallback=0.0){ if(MathAbs(b)<0.0000000001) return fallback; return a/b; }

string DirToString(int d){ if(d>0) return "BUY"; if(d<0) return "SELL"; return "NONE"; }

string StateToString(TransitionState s)
{
   if(s == TS_COMPRESSION) return "COMPRESSION";
   if(s == TS_EXPANSION) return "EXPANSION";
   if(s == TS_ACCEPTANCE) return "ACCEPTANCE";
   return "NORMAL";
}

string SessionLabel(int hour)
{
   if(hour >= 0 && hour < 7) return "ASIA";
   if(hour >= 7 && hour < 13) return "EUROPE";
   if(hour >= 13 && hour < 20) return "NY";
   return "LATE";
}

bool StartsWith(string text, string prefix){ return StringFind(text, prefix, 0) == 0; }

// ==================================================================
// V5.14B — Asset TP Bias Engine
// Cambio único sobre V5.13B:
// - Mantiene entradas, SL, lotaje y gobierno global intactos.
// - Mantiene TP base +12% = RR 5.60.
// - Da más recorrido inicial solo a US500 y US100: +14% = RR 5.70.
// - GER40 y XAUUSD quedan con el TP base de V5.13B.
// ==================================================================
double AssetIdealRewardRiskRatio(string symbol)
{
   if(StartsWith(symbol,"US500"))
      return 5.70;

   if(StartsWith(symbol,"US100"))
      return 5.70;

   return IdealRewardRiskRatio;
}

void ReleaseHandle(int &h){ if(h != INVALID_HANDLE){ IndicatorRelease(h); h = INVALID_HANDLE; } }

double BufferValue(int handle, int buffer_index, int shift)
{
   if(handle == INVALID_HANDLE) return 0.0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, buffer_index, shift, 1, b) != 1) return 0.0;
   return b[0];
}

bool LoadRates(string symbol, ENUM_TIMEFRAMES tf, int start_shift, int bars, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, start_shift, bars, rates);
   return copied >= bars;
}

// ==================================================================
// CSV AUDIT
// ==================================================================
string CsvEscape(string s){ StringReplace(s, "\"", "\"\""); return "\"" + s + "\""; }
string D2(double v, int digits=4){ return DoubleToString(v, digits); }

void CsvWriteLine(string line)
{
   if(g_file == INVALID_HANDLE) return;
   FileWriteString(g_file, line + "\r\n");
   g_rows_written++;
   if((g_rows_written % 250) == 0) FileFlush(g_file);
}

bool OpenCSV()
{
   g_file = FileOpen(InpOutputCSV, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(g_file == INVALID_HANDLE)
   {
      Print("[V4.4] Cannot create CSV: ", InpOutputCSV, " err=", GetLastError());
      return false;
   }

   string header =
      "run_id,event,time,symbol,state,state_direction,direction,decision,reason,order_ticket,volume,price,sl,tp,pnl,r_multiple,rr_planned,transition_score,expansion_phase,lifecycle_score,decay_score,structural_sl,protected_r,"
      "hour_server,dow,session_label,dir_m5,dir_m15,dir_h1,"
      "score_buy,score_sell,regime_buy,regime_sell,"
      "direction_alignment_buy,direction_alignment_sell,ema_slope_buy,ema_slope_sell,"
      "structure_direction_buy,structure_direction_sell,adx_score,roc_buy,roc_sell,"
      "candle_power_buy,candle_power_sell,strength_buy,strength_sell,"
      "expansion_buy,expansion_sell,follow_buy,follow_sell,range_efficiency,"
      "acceptance_buy,acceptance_sell,rejection_buy,rejection_sell,wick_risk_buy,wick_risk_sell,"
      "atr_now,volatility_room_buy,volatility_room_sell,compression_score,"
      "spread_points,spread_quality,liquidity_quality,fibo_level,fibo_zone_score,"
      "swing_position_buy,swing_position_sell,session_activity_score,"
      "equity,balance,margin,open_positions,total_trades_today,symbol_trades_today,avg_win_loss_rule,lot_cap_symbol,risk_money,expected_profit_money,"
      "v518_learning_mode,v518_entry_reader_score,v518_entry_required_score,v518_entry_reader_reason,v518_conflict,v518_false_expansion,v518_immediate_death,v518_mfe_r,v518_mae_r,v518_result_class,"
      "v522_efficiency_ratio,v522_choppiness,v522_trend_slope_buy,v522_trend_slope_sell,v522_atr_regime,v522_compression_expansion,"
      "v522_dirty_trend_buy,v522_dirty_trend_sell,v522_clean_trend_buy,v522_clean_trend_sell,v522_regime_buy,v522_regime_sell,"
      "v524_sim_mode,v524_base_score,v524_regime_bias,v524_sim_final_score,v524_actual_best_asset,v524_sim_preferred_asset,v524_sim_preference_changed";

   CsvWriteLine(header);
   return true;
}

void CloseCSV()
{
   if(g_file != INVALID_HANDLE)
   {
      FileFlush(g_file);
      FileClose(g_file);
      g_file = INVALID_HANDLE;
   }
}

void Audit(MarketContext &ctx, SymbolState &st, int direction, string event, string decision, string reason, ulong ticket, double volume, double price, double sl, double tp, double pnl=0.0, double r_multiple=0.0, double rr_planned=0.0, double transition_score=0.0, string expansion_phase="", double lifecycle_score=0.0, double decay_score=0.0, double structural_sl=0.0, double protected_r=0.0, double lot_cap_symbol=0.0, double risk_money=0.0, double expected_profit_money=0.0, string v518_learning_mode="", double v518_entry_reader_score=0.0, double v518_entry_required_score=0.0, string v518_entry_reader_reason="", double v518_conflict=0.0, double v518_false_expansion=0.0, double v518_immediate_death=0.0, double v518_mfe_r=0.0, double v518_mae_r=0.0, string v518_result_class="", string v524_sim_mode="", double v524_base_score=0.0, double v524_regime_bias=0.0, double v524_sim_final_score=0.0, string v524_actual_best_asset="", string v524_sim_preferred_asset="", string v524_sim_preference_changed="")
{
   string line = "";
   line += CsvEscape(InpRunId) + ",";
   line += CsvEscape(event) + ",";
   line += CsvEscape(TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)) + ",";
   line += CsvEscape(ctx.symbol) + ",";
   line += CsvEscape(StateToString(st.state)) + ",";
   line += CsvEscape(DirToString(st.state_direction)) + ",";
   line += CsvEscape(DirToString(direction)) + ",";
   line += CsvEscape(decision) + ",";
   line += CsvEscape(reason) + ",";
   line += (string)ticket + ",";
   line += D2(volume,2) + ",";
   line += D2(price,5) + ",";
   line += D2(sl,5) + ",";
   line += D2(tp,5) + ",";
   line += D2(pnl,2) + ",";
   line += D2(r_multiple,2) + ",";
   line += D2(rr_planned,2) + ",";
   line += D2(transition_score,2) + ",";
   line += CsvEscape(expansion_phase) + ",";
   line += D2(lifecycle_score,2) + ",";
   line += D2(decay_score,2) + ",";
   line += D2(structural_sl,5) + ",";
   line += D2(protected_r,2) + ",";
   line += (string)ctx.hour_server + ",";
   line += (string)ctx.dow + ",";
   line += CsvEscape(ctx.session_label) + ",";
   line += (string)ctx.dir_m5 + ",";
   line += (string)ctx.dir_m15 + ",";
   line += (string)ctx.dir_h1 + ",";
   line += D2(ctx.score_buy,2) + ",";
   line += D2(ctx.score_sell,2) + ",";
   line += CsvEscape(ctx.regime_buy) + ",";
   line += CsvEscape(ctx.regime_sell) + ",";
   line += D2(ctx.direction_alignment_buy) + ",";
   line += D2(ctx.direction_alignment_sell) + ",";
   line += D2(ctx.ema_slope_buy) + ",";
   line += D2(ctx.ema_slope_sell) + ",";
   line += D2(ctx.structure_direction_buy) + ",";
   line += D2(ctx.structure_direction_sell) + ",";
   line += D2(ctx.adx_score) + ",";
   line += D2(ctx.roc_buy) + ",";
   line += D2(ctx.roc_sell) + ",";
   line += D2(ctx.candle_power_buy) + ",";
   line += D2(ctx.candle_power_sell) + ",";
   line += D2(ctx.strength_buy) + ",";
   line += D2(ctx.strength_sell) + ",";
   line += D2(ctx.expansion_buy) + ",";
   line += D2(ctx.expansion_sell) + ",";
   line += D2(ctx.follow_buy) + ",";
   line += D2(ctx.follow_sell) + ",";
   line += D2(ctx.range_efficiency) + ",";
   line += D2(ctx.acceptance_buy) + ",";
   line += D2(ctx.acceptance_sell) + ",";
   line += D2(ctx.rejection_buy) + ",";
   line += D2(ctx.rejection_sell) + ",";
   line += D2(ctx.wick_risk_buy) + ",";
   line += D2(ctx.wick_risk_sell) + ",";
   line += D2(ctx.atr_now,6) + ",";
   line += D2(ctx.volatility_room_buy) + ",";
   line += D2(ctx.volatility_room_sell) + ",";
   line += D2(ctx.compression_score) + ",";
   line += D2(ctx.spread_points,2) + ",";
   line += D2(ctx.spread_quality) + ",";
   line += D2(ctx.liquidity_quality) + ",";
   line += D2(ctx.fibo_level) + ",";
   line += D2(ctx.fibo_zone_score) + ",";
   line += D2(ctx.swing_position_buy) + ",";
   line += D2(ctx.swing_position_sell) + ",";
   line += D2(ctx.session_activity_score) + ",";
   line += D2(AccountInfoDouble(ACCOUNT_EQUITY),2) + ",";
   line += D2(AccountInfoDouble(ACCOUNT_BALANCE),2) + ",";
   line += D2(AccountInfoDouble(ACCOUNT_MARGIN),2) + ",";
   line += (string)PositionsTotal() + ",";
   line += (string)g_total_trades_today + ",";
   line += (string)st.trades_today + ",";
   line += CsvEscape("ASYMMETRY_TARGET_AVG_WIN_GE_3R_LOSS_1R") + ",";
   line += D2(lot_cap_symbol,2) + ",";
   line += D2(risk_money,2) + ",";
   line += D2(expected_profit_money,2) + ",";
   line += CsvEscape(v518_learning_mode) + ",";
   line += D2(v518_entry_reader_score,2) + ",";
   line += D2(v518_entry_required_score,2) + ",";
   line += CsvEscape(v518_entry_reader_reason) + ",";
   line += D2(v518_conflict,4) + ",";
   line += D2(v518_false_expansion,2) + ",";
   line += D2(v518_immediate_death,2) + ",";
   line += D2(v518_mfe_r,2) + ",";
   line += D2(v518_mae_r,2) + ",";
   line += CsvEscape(v518_result_class) + ",";
   line += D2(ctx.v522_efficiency_ratio,4) + ",";
   line += D2(ctx.v522_choppiness,4) + ",";
   line += D2(ctx.v522_trend_slope_buy,4) + ",";
   line += D2(ctx.v522_trend_slope_sell,4) + ",";
   line += D2(ctx.v522_atr_regime,4) + ",";
   line += D2(ctx.v522_compression_expansion,4) + ",";
   line += D2(ctx.v522_dirty_trend_buy,4) + ",";
   line += D2(ctx.v522_dirty_trend_sell,4) + ",";
   line += D2(ctx.v522_clean_trend_buy,4) + ",";
   line += D2(ctx.v522_clean_trend_sell,4) + ",";
   line += CsvEscape(ctx.v522_regime_buy) + ",";
   line += CsvEscape(ctx.v522_regime_sell) + ",";
   line += CsvEscape(v524_sim_mode) + ",";
   line += D2(v524_base_score,2) + ",";
   line += D2(v524_regime_bias,2) + ",";
   line += D2(v524_sim_final_score,2) + ",";
   line += CsvEscape(v524_actual_best_asset) + ",";
   line += CsvEscape(v524_sim_preferred_asset) + ",";
   line += CsvEscape(v524_sim_preference_changed);

   CsvWriteLine(line);
}

// ==================================================================
// SYMBOL INIT
// ==================================================================
bool InitSymbolState(string sym, SymbolState &st)
{
   st.symbol = sym;
   st.last_bar_time = 0;
   st.state = TS_NORMAL;
   st.state_direction = 0;
   st.state_age_bars = 0;
   st.compression_time = 0;
   st.expansion_time = 0;
   st.trades_today = 0;
   st.consecutive_losses = 0;
   st.cooldown_until = 0;

   SymbolSelect(sym, true);

   st.h_atr_decision      = iATR(sym, InpDecisionTF, InpATRPeriod);
   st.h_ema_fast_micro    = iMA(sym, InpMicroTF,    InpFastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   st.h_ema_fast_decision = iMA(sym, InpDecisionTF, InpFastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   st.h_ema_fast_context  = iMA(sym, InpContextTF,  InpFastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   st.h_ema_slow_micro    = iMA(sym, InpMicroTF,    InpSlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   st.h_ema_slow_decision = iMA(sym, InpDecisionTF, InpSlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   st.h_ema_slow_context  = iMA(sym, InpContextTF,  InpSlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   st.h_adx_decision      = iADX(sym, InpDecisionTF, InpADXPeriod);

   if(st.h_atr_decision == INVALID_HANDLE ||
      st.h_ema_fast_micro == INVALID_HANDLE ||
      st.h_ema_fast_decision == INVALID_HANDLE ||
      st.h_ema_fast_context == INVALID_HANDLE ||
      st.h_ema_slow_micro == INVALID_HANDLE ||
      st.h_ema_slow_decision == INVALID_HANDLE ||
      st.h_ema_slow_context == INVALID_HANDLE ||
      st.h_adx_decision == INVALID_HANDLE)
   {
      Print("[V4.4] Invalid indicator handle for ", sym, " err=", GetLastError());
      return false;
   }

   return true;
}

void SplitSymbolsAndInit()
{
   string parts[];
   int n = StringSplit(InpSymbolsCSV, ',', parts);
   ArrayResize(g_states, 0);

   for(int i=0; i<n; i++)
   {
      string sym = Trim(parts[i]);
      if(sym == "") continue;

      SymbolState st;
      if(!InitSymbolState(sym, st)) continue;

      int sz = ArraySize(g_states);
      ArrayResize(g_states, sz+1);
      g_states[sz] = st;
   }
}

void ReleaseAll()
{
   for(int i=0; i<ArraySize(g_states); i++)
   {
      ReleaseHandle(g_states[i].h_atr_decision);
      ReleaseHandle(g_states[i].h_ema_fast_micro);
      ReleaseHandle(g_states[i].h_ema_fast_decision);
      ReleaseHandle(g_states[i].h_ema_fast_context);
      ReleaseHandle(g_states[i].h_ema_slow_micro);
      ReleaseHandle(g_states[i].h_ema_slow_decision);
      ReleaseHandle(g_states[i].h_ema_slow_context);
      ReleaseHandle(g_states[i].h_adx_decision);
   }
}

// ==================================================================
// METRICS
// ==================================================================
int InferDirection(int h_fast, int h_slow)
{
   double fast1 = BufferValue(h_fast,0,1);
   double fast4 = BufferValue(h_fast,0,4);
   double slow1 = BufferValue(h_slow,0,1);
   if(fast1<=0.0 || slow1<=0.0) return 0;
   if(fast1 > slow1 && fast1 > fast4) return 1;
   if(fast1 < slow1 && fast1 < fast4) return -1;
   return 0;
}

double DirectionAlignment(int d1,int d2,int d3,int target)
{
   if(target==0) return 0.0;
   int c=0; if(d1==target)c++; if(d2==target)c++; if(d3==target)c++;
   return SafeDiv(c,3.0);
}

double EMASlopeScore(int h_fast,double atr,int target)
{
   if(target==0 || atr<=0.0) return 0.0;
   double ma1=BufferValue(h_fast,0,1);
   double ma6=BufferValue(h_fast,0,6);
   if(ma1<=0.0 || ma6<=0.0) return 0.0;
   double slope=(ma1-ma6)/atr;
   if(target<0) slope=-slope;
   return Clamp01(slope);
}

double StructureDirection(MqlRates &r[],int count,int target)
{
   if(target==0) return 0.0;
   int up=0,down=0;
   for(int i=1;i<count-1;i++){ if(r[i].close>r[i+1].close)up++; if(r[i].close<r[i+1].close)down++; }
   if(target>0) return SafeDiv(up,count-2);
   return SafeDiv(down,count-2);
}

double ROCScore(MqlRates &r[],int count,double atr,int target)
{
   if(target==0 || atr<=0.0) return 0.0;
   double move=r[1].close-r[count-1].close;
   if(target<0) move=-move;
   return Clamp01(move/(atr*2.0));
}

double CandlePower(MqlRates &r[],int count,int target)
{
   if(target==0) return 0.0;
   double directional_body=0.0,total_range=0.0;
   for(int i=1;i<count;i++)
   {
      double body=MathAbs(r[i].close-r[i].open);
      double range=r[i].high-r[i].low;
      if(range<=0.0) continue;
      bool ok=(target>0 && r[i].close>r[i].open) || (target<0 && r[i].close<r[i].open);
      if(ok) directional_body+=body;
      total_range+=range;
   }
   return Clamp01(SafeDiv(directional_body,total_range));
}

double ExpansionScore(MqlRates &r[],int count,double atr,int target)
{
   if(target==0 || atr<=0.0) return 0.0;
   int directional_bars=0; double total_range=0.0;
   for(int i=1;i<count;i++)
   {
      bool bullish=r[i].close>r[i].open;
      bool bearish=r[i].close<r[i].open;
      if((target>0 && bullish) || (target<0 && bearish)) directional_bars++;
      total_range += r[i].high-r[i].low;
   }
   double directional_ratio=SafeDiv(directional_bars,count-1);
   double avg_range=SafeDiv(total_range,count-1);
   double normalized_range=SafeDiv(avg_range,atr);
   return Clamp01(directional_ratio*normalized_range);
}

double FollowThrough(MqlRates &r[],int count,int target)
{
   if(target==0) return 0.0;
   int cont=0;
   for(int i=1;i<count-1;i++)
   {
      if(target>0 && r[i].close>=r[i+1].close) cont++;
      if(target<0 && r[i].close<=r[i+1].close) cont++;
   }
   return SafeDiv(cont,count-2);
}

double RangeEfficiency(MqlRates &r[],int count)
{
   double path=0.0;
   for(int i=1;i<count-1;i++) path += MathAbs(r[i].close-r[i+1].close);
   double net=MathAbs(r[1].close-r[count-1].close);
   return Clamp01(SafeDiv(net,path));
}


// ==================================================================
// V5.22 — MARKET REGIME INTELLIGENCE OBSERVER METRICS
// Pure observation metrics. They do not block, resize, protect or modify trades.
// ==================================================================
double V522EfficiencyRatio(MqlRates &r[],int count)
{
   int n=MathMin(count-1, MathMax(10,V522_RegimeLookbackBars));
   double path=0.0;
   for(int i=1;i<n;i++) path += MathAbs(r[i].close-r[i+1].close);
   double net=MathAbs(r[1].close-r[n].close);
   return Clamp01(SafeDiv(net,path));
}

double V522Choppiness(MqlRates &r[],int count)
{
   int n=MathMin(count-1, MathMax(10,V522_RegimeLookbackBars));
   double tr_sum=0.0;
   double high=-DBL_MAX, low=DBL_MAX;
   for(int i=1;i<=n;i++)
   {
      double prev_close = (i+1<count ? r[i+1].close : r[i].close);
      double tr = MathMax(r[i].high-r[i].low, MathMax(MathAbs(r[i].high-prev_close), MathAbs(r[i].low-prev_close)));
      tr_sum += tr;
      if(r[i].high>high) high=r[i].high;
      if(r[i].low<low) low=r[i].low;
   }
   double range=high-low;
   if(range<=0.0 || tr_sum<=0.0 || n<=1) return 1.0;
   double raw = 100.0 * (MathLog(tr_sum/range)/MathLog(10.0)) / (MathLog((double)n)/MathLog(10.0));
   return Clamp01(raw/100.0);
}

double V522ATRRegime(MqlRates &r[],int count,double atr_now)
{
   int n=MathMin(count-2, MathMax(12,V522_RegimeLookbackBars));
   double tr_sum=0.0;
   for(int i=2;i<=n+1;i++)
   {
      double prev_close = (i+1<count ? r[i+1].close : r[i].close);
      double tr = MathMax(r[i].high-r[i].low, MathMax(MathAbs(r[i].high-prev_close), MathAbs(r[i].low-prev_close)));
      tr_sum += tr;
   }
   double avg_tr=SafeDiv(tr_sum,n);
   if(avg_tr<=0.0) return 1.0;
   return MathMax(0.0, MathMin(3.0, atr_now/avg_tr));
}

double V522TrendSlope(MqlRates &r[],int count,double atr,int target)
{
   if(target==0 || atr<=0.0) return 0.0;
   int n=MathMin(count-1, MathMax(10,V522_RegimeLookbackBars));
   double move=r[1].close-r[n].close;
   if(target<0) move=-move;
   return Clamp01(move/(atr*3.0));
}

double V522DirtyTrendScore(MarketContext &ctx,int direction)
{
   double slope = (direction>0 ? ctx.v522_trend_slope_buy : ctx.v522_trend_slope_sell);
   double follow = (direction>0 ? ctx.follow_buy : ctx.follow_sell);
   double strength = (direction>0 ? ctx.strength_buy : ctx.strength_sell);
   double expansion = (direction>0 ? ctx.expansion_buy : ctx.expansion_sell);
   // Dirty trend accepts imperfect candles/wicks if there is actual directional persistence.
   return Clamp01(ctx.v522_efficiency_ratio*0.28 + slope*0.24 + follow*0.18 + strength*0.18 + expansion*0.12 - ctx.v522_choppiness*0.10);
}

double V522CleanTrendScore(MarketContext &ctx,int direction)
{
   double align = (direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell);
   double slope = (direction>0 ? ctx.v522_trend_slope_buy : ctx.v522_trend_slope_sell);
   double wick = (direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell);
   double accept = (direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell);
   double follow = (direction>0 ? ctx.follow_buy : ctx.follow_sell);
   return Clamp01(ctx.v522_efficiency_ratio*0.24 + align*0.22 + slope*0.20 + accept*0.14 + follow*0.12 - wick*0.12 - ctx.v522_choppiness*0.08);
}

string V522RegimeLabel(MarketContext &ctx,int direction)
{
   double dirty = (direction>0 ? ctx.v522_dirty_trend_buy : ctx.v522_dirty_trend_sell);
   double clean = (direction>0 ? ctx.v522_clean_trend_buy : ctx.v522_clean_trend_sell);
   double expansion = (direction>0 ? ctx.expansion_buy : ctx.expansion_sell);
   double follow = (direction>0 ? ctx.follow_buy : ctx.follow_sell);
   double rejection = (direction>0 ? ctx.rejection_buy : ctx.rejection_sell);
   double wick = (direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell);

   if(ctx.v522_choppiness >= V522_ChopHigh && ctx.v522_efficiency_ratio < V522_DirtyTrendMinEfficiency)
      return "V522_CHOP";
   if(clean >= 0.58 && ctx.v522_efficiency_ratio >= V522_CleanTrendMinEfficiency && wick <= 0.48)
      return "V522_TREND_CLEAN";
   if(dirty >= 0.48 && ctx.v522_efficiency_ratio >= V522_DirtyTrendMinEfficiency && follow >= 0.44)
      return "V522_TREND_DIRTY";
   if(expansion >= 0.60 && ctx.v522_atr_regime >= 1.05 && rejection <= 0.55)
      return "V522_EXPANSION";
   if(expansion >= 0.58 && (rejection > 0.62 || wick > 0.62))
      return "V522_EXHAUSTION";
   if(ctx.compression_score >= 0.55 && ctx.v522_atr_regime <= 0.92)
      return "V522_COMPRESSION";
   return "V522_RANGE";
}


// ==================================================================
// V5.24 — REGIME-AWARE RANKING BIAS SIMULATOR
// Pure simulation: these functions never block, never select, never modify trades.
// They only calculate a hypothetical regime-aware priority to audit in CSV.
// ==================================================================
string V524DirectionRegime(MarketContext &ctx,int direction)
{
   return (direction>0 ? ctx.v522_regime_buy : ctx.v522_regime_sell);
}

double V524RegimeBiasScore(MarketContext &ctx,int direction)
{
   if(!EnableV524RankingBiasSimulator)
      return 0.0;

   string symbol = ctx.symbol;
   string regime = V524DirectionRegime(ctx,direction);
   double score = 0.0;

   if(StartsWith(symbol,"XAU"))
   {
      if(regime=="V522_TREND_DIRTY") score += V524_XAU_TrendDirtyBonus;
      else if(regime=="V522_TREND_CLEAN") score += V524_XAU_TrendCleanBonus;
      else if(regime=="V522_CHOP") score += V524_XAU_ChopPenalty;
   }
   else if(StartsWith(symbol,"US500"))
   {
      if(regime=="V522_TREND_CLEAN") score += V524_US500_TrendCleanBonus;
      else if(regime=="V522_TREND_DIRTY") score += V524_US500_TrendDirtyPenalty;
      else if(regime=="V522_RANGE") score += V524_US500_RangePenalty;
      else if(regime=="V522_CHOP") score += V524_US500_ChopPenalty;
   }
   else if(StartsWith(symbol,"US100"))
   {
      if(regime=="V522_EXPANSION") score += V524_US100_ExpansionBonus;
      else if(regime=="V522_TREND_CLEAN") score += V524_US100_TrendCleanBonus;
      else if(regime=="V522_TREND_DIRTY") score += V524_US100_TrendDirtyPenalty;
      else if(regime=="V522_RANGE") score += V524_US100_RangePenalty;
      else if(regime=="V522_CHOP") score += V524_US100_ChopPenalty;
   }

   if(regime=="V522_CHOP")
      score += V524_GlobalChopPenalty;

   return score;
}

double V524SimulatedFinalScore(MarketContext &ctx,int direction,double base_score)
{
   return base_score + V524RegimeBiasScore(ctx,direction);
}

double AcceptanceScore(MqlRates &r[],int count,int target)
{
   if(target==0) return 0.0;
   double high=-DBL_MAX,low=DBL_MAX;
   for(int i=1;i<count;i++){ if(r[i].high>high)high=r[i].high; if(r[i].low<low)low=r[i].low; }
   double impulse=high-low;
   if(impulse<=0.0) return 0.0;
   double current=r[1].close;
   double pullback=(target>0 ? high-current : current-low);
   return Clamp01(1.0-SafeDiv(pullback,impulse,1.0));
}

double RejectionSpeed(MqlRates &r[],int count,int target)
{
   if(target==0) return 0.0;
   double adverse=0.0,favorable=0.0;
   for(int i=1;i<count;i++)
   {
      double move=r[i].close-r[i].open;
      if(target<0) move=-move;
      if(move>=0.0) favorable+=move; else adverse+=MathAbs(move);
   }
   return Clamp01(SafeDiv(adverse,favorable+adverse));
}

double WickRisk(MqlRates &r[],int count,int target)
{
   if(target==0) return 1.0;
   double adverse_wick=0.0,total_range=0.0;
   for(int i=1;i<count;i++)
   {
      double range=r[i].high-r[i].low;
      if(range<=0.0) continue;
      double upper=r[i].high-MathMax(r[i].open,r[i].close);
      double lower=MathMin(r[i].open,r[i].close)-r[i].low;
      if(target>0) adverse_wick+=MathMax(0.0,upper);
      if(target<0) adverse_wick+=MathMax(0.0,lower);
      total_range+=range;
   }
   return Clamp01(SafeDiv(adverse_wick,total_range));
}

double VolatilityRoom(MqlRates &r[],int count,double atr,int target)
{
   if(target==0 || atr<=0.0) return 0.0;
   double current=r[1].close;
   if(target>0)
   {
      double barrier=-DBL_MAX;
      for(int i=2;i<count;i++) if(r[i].high>barrier) barrier=r[i].high;
      return Clamp01(SafeDiv(barrier-current,atr));
   }
   double barrier=DBL_MAX;
   for(int i=2;i<count;i++) if(r[i].low<barrier) barrier=r[i].low;
   return Clamp01(SafeDiv(current-barrier,atr));
}

double CompressionScore(MqlRates &r[],int count,double atr)
{
   if(atr<=0.0) return 0.0;
   double high=-DBL_MAX,low=DBL_MAX;
   for(int i=1;i<count;i++){ if(r[i].high>high) high=r[i].high; if(r[i].low<low) low=r[i].low; }
   double range=high-low;
   return Clamp01(1.0-SafeDiv(range,atr*count*0.5));
}

double FiboLevel(MqlRates &r[],int count)
{
   double high=-DBL_MAX,low=DBL_MAX;
   for(int i=1;i<count;i++){ if(r[i].high>high)high=r[i].high; if(r[i].low<low)low=r[i].low; }
   double range=high-low;
   if(range<=0.0) return -1.0;
   return SafeDiv(r[1].close-low,range,-1.0);
}

double FiboZoneScore(double level)
{
   if(level<0.0) return 0.0;
   if(level>=0.382 && level<=0.618) return 1.0;
   if(level>=0.25 && level<=0.75) return 0.6;
   return 0.2;
}

double SwingPositionScore(double level,int target)
{
   if(level<0.0 || target==0) return 0.0;
   if(target>0)
   {
      if(level>=0.382 && level<=0.786) return 1.0;
      if(level>0.786) return 0.3;
      return 0.5;
   }
   if(level>=0.214 && level<=0.618) return 1.0;
   if(level<0.214) return 0.3;
   return 0.5;
}

double SpreadQuality(string symbol,double spread_points,double atr)
{
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   if(point<=0.0) point=0.00001;
   if(atr<=0.0) return 0.0;
   double atr_points=atr/point;
   double ratio=SafeDiv(spread_points,atr_points,1.0);
   if(ratio<=0.05) return 1.0;
   if(ratio>=0.20) return 0.0;
   return Clamp01(1.0-(ratio-0.05)/0.15);
}

double LiquidityQuality(MqlRates &r[],int count)
{
   if(count<10) return 0.5;
   double cur=(double)r[1].tick_volume;
   double sum=0.0; int c=0;
   for(int i=2;i<count;i++){ sum+=(double)r[i].tick_volume; c++; }
   double avg=SafeDiv(sum,c);
   if(avg<=0.0) return 0.5;
   double ratio=cur/avg;
   if(ratio<=0.5) return 0.25;
   if(ratio>=1.5) return 1.0;
   return Clamp01(0.25+(ratio-0.5)*0.75);
}

double SessionActivity(MqlRates &r[],int count)
{
   if(count<10) return 0.0;
   double current_range=r[1].high-r[1].low;
   double avg_range=0.0;
   for(int i=2;i<count;i++) avg_range += r[i].high-r[i].low;
   avg_range=SafeDiv(avg_range,count-2);
   if(avg_range<=0.0) return 0.0;
   double ratio=current_range/avg_range;
   if(ratio<0.5) return 0.2;
   if(ratio<=1.5) return Clamp01(0.2+(ratio-0.5)*0.8);
   return Clamp01(1.0-(ratio-1.5)/2.0);
}

string Regime(double expansion,double acceptance,double follow,double wick,double rejection,double align,double strength,double compression)
{
   if(wick>0.65 || rejection>0.65) return "TRAP_RISK";
   if(expansion>0.65 && acceptance>0.65 && follow>0.55) return "EXPANSION_ACCEPTED";
   if(align>0.65 && strength>0.60) return "TRENDING";
   if(compression>0.60) return "COMPRESSION";
   return "RANGE_OR_NOISE";
}

double ScoreForDirection(MarketContext &ctx,int direction)
{
   double raw=0.0;
   if(direction>0)
      raw=ctx.direction_alignment_buy*W_Direction+ctx.strength_buy*W_Strength+ctx.expansion_buy*W_Expansion+ctx.acceptance_buy*W_Acceptance+ctx.volatility_room_buy*W_VolatilityRoom+ctx.liquidity_quality*W_Liquidity+ctx.fibo_zone_score*W_Structure+ctx.session_activity_score*W_Session-ctx.wick_risk_buy*W_TrapPenalty;
   else
      raw=ctx.direction_alignment_sell*W_Direction+ctx.strength_sell*W_Strength+ctx.expansion_sell*W_Expansion+ctx.acceptance_sell*W_Acceptance+ctx.volatility_room_sell*W_VolatilityRoom+ctx.liquidity_quality*W_Liquidity+ctx.fibo_zone_score*W_Structure+ctx.session_activity_score*W_Session-ctx.wick_risk_sell*W_TrapPenalty;
   if(raw<0.0) raw=0.0;
   if(raw>100.0) raw=100.0;
   return raw;
}

// ==================================================================
// CONTEXT + DRIVER
// ==================================================================
bool BuildContext(int idx,MarketContext &ctx)
{
   SymbolState st=g_states[idx];
   string symbol=st.symbol;
   int bars=MathMax(InpLookbackBars+5,60);
   MqlRates r[];
   if(!LoadRates(symbol,InpDecisionTF,0,bars,r)) return false;

   ctx.symbol=symbol;
   ctx.signal_time=r[1].time;
   ctx.signal_price=r[1].close;

   MqlDateTime dt;
   TimeToStruct(ctx.signal_time,dt);
   ctx.hour_server=dt.hour;
   ctx.dow=dt.day_of_week;
   ctx.session_label=SessionLabel(dt.hour);

   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   if(point<=0.0) point=0.00001;
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(symbol,SYMBOL_BID);
   ctx.spread_points=SafeDiv(ask-bid,point);

   ctx.atr_now=BufferValue(st.h_atr_decision,0,1);
   if(ctx.atr_now<=0.0) return false;

   ctx.dir_m5=InferDirection(st.h_ema_fast_micro,st.h_ema_slow_micro);
   ctx.dir_m15=InferDirection(st.h_ema_fast_decision,st.h_ema_slow_decision);
   ctx.dir_h1=InferDirection(st.h_ema_fast_context,st.h_ema_slow_context);

   ctx.direction_alignment_buy=DirectionAlignment(ctx.dir_m5,ctx.dir_m15,ctx.dir_h1,1);
   ctx.direction_alignment_sell=DirectionAlignment(ctx.dir_m5,ctx.dir_m15,ctx.dir_h1,-1);

   ctx.ema_slope_buy=EMASlopeScore(st.h_ema_fast_decision,ctx.atr_now,1);
   ctx.ema_slope_sell=EMASlopeScore(st.h_ema_fast_decision,ctx.atr_now,-1);

   ctx.structure_direction_buy=StructureDirection(r,bars,1);
   ctx.structure_direction_sell=StructureDirection(r,bars,-1);

   ctx.adx_score=Clamp01((BufferValue(st.h_adx_decision,0,1)-15.0)/25.0);

   ctx.roc_buy=ROCScore(r,bars,ctx.atr_now,1);
   ctx.roc_sell=ROCScore(r,bars,ctx.atr_now,-1);

   ctx.candle_power_buy=CandlePower(r,bars,1);
   ctx.candle_power_sell=CandlePower(r,bars,-1);

   ctx.strength_buy=Clamp01(ctx.adx_score*0.35+ctx.roc_buy*0.35+ctx.candle_power_buy*0.30);
   ctx.strength_sell=Clamp01(ctx.adx_score*0.35+ctx.roc_sell*0.35+ctx.candle_power_sell*0.30);

   ctx.expansion_buy=ExpansionScore(r,bars,ctx.atr_now,1);
   ctx.expansion_sell=ExpansionScore(r,bars,ctx.atr_now,-1);

   ctx.follow_buy=FollowThrough(r,bars,1);
   ctx.follow_sell=FollowThrough(r,bars,-1);

   ctx.range_efficiency=RangeEfficiency(r,bars);

   ctx.acceptance_buy=AcceptanceScore(r,bars,1);
   ctx.acceptance_sell=AcceptanceScore(r,bars,-1);

   ctx.rejection_buy=RejectionSpeed(r,bars,1);
   ctx.rejection_sell=RejectionSpeed(r,bars,-1);

   ctx.wick_risk_buy=WickRisk(r,bars,1);
   ctx.wick_risk_sell=WickRisk(r,bars,-1);

   ctx.volatility_room_buy=VolatilityRoom(r,bars,ctx.atr_now,1);
   ctx.volatility_room_sell=VolatilityRoom(r,bars,ctx.atr_now,-1);

   ctx.compression_score=CompressionScore(r,bars,ctx.atr_now);

   ctx.spread_quality=SpreadQuality(symbol,ctx.spread_points,ctx.atr_now);
   ctx.liquidity_quality=Clamp01(ctx.spread_quality*0.65+LiquidityQuality(r,bars)*0.35);

   ctx.fibo_level=FiboLevel(r,bars);
   ctx.fibo_zone_score=FiboZoneScore(ctx.fibo_level);
   ctx.swing_position_buy=SwingPositionScore(ctx.fibo_level,1);
   ctx.swing_position_sell=SwingPositionScore(ctx.fibo_level,-1);

   ctx.session_activity_score=SessionActivity(r,bars);

   // V5.22 — market regime intelligence observer metrics.
   // These values are audit-only and must not affect entries/exits/risk.
   ctx.v522_efficiency_ratio = (EnableV522MarketRegimeObserver ? V522EfficiencyRatio(r,bars) : 0.0);
   ctx.v522_choppiness = (EnableV522MarketRegimeObserver ? V522Choppiness(r,bars) : 0.0);
   ctx.v522_trend_slope_buy = (EnableV522MarketRegimeObserver ? V522TrendSlope(r,bars,ctx.atr_now,1) : 0.0);
   ctx.v522_trend_slope_sell = (EnableV522MarketRegimeObserver ? V522TrendSlope(r,bars,ctx.atr_now,-1) : 0.0);
   ctx.v522_atr_regime = (EnableV522MarketRegimeObserver ? V522ATRRegime(r,bars,ctx.atr_now) : 0.0);
   ctx.v522_compression_expansion = (EnableV522MarketRegimeObserver ? (MathMax(ctx.expansion_buy,ctx.expansion_sell)-ctx.compression_score) : 0.0);
   ctx.v522_dirty_trend_buy = (EnableV522MarketRegimeObserver ? V522DirtyTrendScore(ctx,1) : 0.0);
   ctx.v522_dirty_trend_sell = (EnableV522MarketRegimeObserver ? V522DirtyTrendScore(ctx,-1) : 0.0);
   ctx.v522_clean_trend_buy = (EnableV522MarketRegimeObserver ? V522CleanTrendScore(ctx,1) : 0.0);
   ctx.v522_clean_trend_sell = (EnableV522MarketRegimeObserver ? V522CleanTrendScore(ctx,-1) : 0.0);
   ctx.v522_regime_buy = (EnableV522MarketRegimeObserver ? V522RegimeLabel(ctx,1) : "V522_DISABLED");
   ctx.v522_regime_sell = (EnableV522MarketRegimeObserver ? V522RegimeLabel(ctx,-1) : "V522_DISABLED");

   ctx.score_buy=ScoreForDirection(ctx,1);
   ctx.score_sell=ScoreForDirection(ctx,-1);

   ctx.regime_buy=Regime(ctx.expansion_buy,ctx.acceptance_buy,ctx.follow_buy,ctx.wick_risk_buy,ctx.rejection_buy,ctx.direction_alignment_buy,ctx.strength_buy,ctx.compression_score);
   ctx.regime_sell=Regime(ctx.expansion_sell,ctx.acceptance_sell,ctx.follow_sell,ctx.wick_risk_sell,ctx.rejection_sell,ctx.direction_alignment_sell,ctx.strength_sell,ctx.compression_score);

   return true;
}

DriverThresholds GetDriver(string symbol)
{
   DriverThresholds d;
   d.compression_min=0.52;
   d.expansion_min=0.60;
   d.acceptance_min=0.56;
   d.follow_min=0.48;
   d.wick_max=0.46;
   d.direction_align_min=0.58;
   d.score_min=64.0;
   d.start_hour=0;
   d.end_hour=24;

   // XAUUSD is already the most readable asset; keep stricter liquidity/acceptance.
   if(StartsWith(symbol,"XAU"))
   {
      d.compression_min=0.56;
      d.expansion_min=0.62;
      d.acceptance_min=0.60;
      d.follow_min=0.52;
      d.wick_max=0.43;
      d.direction_align_min=0.64;
      d.score_min=68.0;
      d.start_hour=7;
      d.end_hour=20;
   }
   // US500 accepts with smoother, slower continuation. Do not demand perfect follow.
   else if(StartsWith(symbol,"US500"))
   {
      d.compression_min=0.50;
      d.expansion_min=0.59;
      d.acceptance_min=0.55;
      d.follow_min=0.46;
      d.wick_max=0.47;
      d.direction_align_min=0.56;
      d.score_min=62.0;
      d.start_hour=13;
      d.end_hour=20;
   }
   // GER40 is abrupt: impulse and low rejection are more important than beautiful follow.
   else if(StartsWith(symbol,"GER40"))
   {
      d.compression_min=0.52;
      d.expansion_min=0.61;
      d.acceptance_min=0.56;
      d.follow_min=0.46;
      d.wick_max=0.46;
      d.direction_align_min=0.58;
      d.score_min=63.0;
      d.start_hour=GER40_TimingStartHour;
      d.end_hour=GER40_TimingEndHour;
   }
   // US100 is volatile: require controlled wick but allow delayed acceptance.
   else if(StartsWith(symbol,"US100"))
   {
      d.compression_min=0.51;
      d.expansion_min=0.61;
      d.acceptance_min=0.55;
      d.follow_min=0.46;
      d.wick_max=0.45;
      d.direction_align_min=0.58;
      d.score_min=63.0;
      d.start_hour=13;
      d.end_hour=20;
   }

   return d;
}

// ==================================================================
// RISK GOVERNOR
// ==================================================================
void ResetDailyCountersIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);

   if(g_day_of_year != dt.day_of_year)
   {
      g_day_of_year=dt.day_of_year;
      g_day_start_equity=equity;
      g_total_trades_today=0;
      for(int i=0;i<ArraySize(g_states);i++) g_states[i].trades_today=0;
   }

   if(g_peak_equity<=0.0 || equity>g_peak_equity)
      g_peak_equity=equity;
}

void UpdateRiskAnchors(){ ResetDailyCountersIfNeeded(); }

int CountOpenPositionsAll()
{
   int c=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) c++;
   }
   return c;
}

bool HasPositionSameSymbol(string symbol)
{
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==symbol) return true;
   }
   return false;
}

bool HasOppositePosition(string symbol,int direction)
{
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      if(direction>0 && type==POSITION_TYPE_SELL) return true;
      if(direction<0 && type==POSITION_TYPE_BUY) return true;
   }
   return false;
}


double SelectorQualityScore(MarketContext &ctx,int direction)
{
   double transition = AdaptiveTransitionScore(ctx,direction);
   double lifecycle  = ExpansionLifecycleScore(ctx,direction);
   double decay      = ExpansionDecayScore(ctx,direction);
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;

   // This is not a signal score. It is a selector score:
   // signal quality + market cleanliness + post-entry survivability.
   double q = 0.0;
   q += transition * 0.28;
   q += lifecycle  * 0.20;
   q += (100.0-decay) * 0.18;
   q += acceptance * 10.0;
   q += follow * 8.0;
   q += (1.0-wick) * 8.0;
   q += align * 5.0;
   q += ctx.liquidity_quality * 4.0;
   q += ctx.spread_quality * 3.0;

   if(q<0.0) q=0.0;
   if(q>100.0) q=100.0;
   return q;
}

double RequiredSelectorQuality(string symbol)
{
   if(EnableAssetSpecificEngine)
   {
      if(IsGoldSymbol(symbol))
         return SelectorQualityGold;
      if(StartsWith(symbol,"US500"))
         return SelectorQualityUS500;
      if(StartsWith(symbol,"US100"))
         return SelectorQualityUS100;
      if(StartsWith(symbol,"GER40"))
         return SelectorQualityGER40;
   }

   if(StartsWith(symbol,"US500"))
      return MinSelectorQualityUS500;

   if(IsIndexSymbol(symbol))
      return MinSelectorQualityIndex;

   return MinSelectorQuality;
}

void UpdateEquityLock()
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);

   if(equity>g_peak_equity)
      g_peak_equity=equity;

   if(balance>g_max_balance_seen)
      g_max_balance_seen=balance;

   if(!EnableEquityProfitLock)
      return;

   double peak_profit = g_peak_equity - g_initial_equity;

   if(peak_profit >= ProfitLockActivationMoney)
   {
      double floor_candidate = g_initial_equity + peak_profit * ProfitLockRatio;
      if(floor_candidate > g_equity_lock_floor)
         g_equity_lock_floor = floor_candidate;
   }
}

bool EquityLockAllows(string &reason)
{
   if(!EnableEquityProfitLock)
   {
      reason="EQUITY_LOCK_DISABLED";
      return true;
   }

   datetime now = TimeCurrent();
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);

   // V4.0: the profit lock is a circuit breaker, not a permanent account killer.
   // In V3.6, once equity fell below the locked floor, equity could not recover
   // because no new trades were allowed; the EA stayed blocked forever.
   if(g_equity_lock_pause_until>0)
   {
      if(now < g_equity_lock_pause_until)
      {
         reason="EQUITY_LOCK_PAUSE_ACTIVE";
         return false;
      }

      if(EquityLockRearmAfterPause)
      {
         g_peak_equity = equity;
         g_equity_lock_floor = 0.0;
         g_equity_lock_pause_until = 0;
      }
   }

   UpdateEquityLock();

   equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double giveback=g_peak_equity-equity;

   if(g_equity_lock_floor>g_initial_equity && equity<=g_equity_lock_floor)
   {
      int pause_seconds = MathMax(1, EquityLockPauseHours) * 3600;
      g_equity_lock_pause_until = now + pause_seconds;
      reason="EQUITY_LOCK_FLOOR_REACHED_PAUSE";
      return false;
   }

   if(giveback>=ProfitGivebackPauseMoney && g_peak_equity-g_initial_equity>=ProfitLockActivationMoney)
   {
      int pause_seconds = MathMax(1, EquityLockPauseHours) * 3600;
      g_equity_lock_pause_until = now + pause_seconds;
      reason="PROFIT_GIVEBACK_PAUSE";
      return false;
   }

   reason="EQUITY_LOCK_ALLOW";
   return true;
}

int SymbolIndexByName(string symbol)
{
   for(int i=0;i<ArraySize(g_states);i++)
      if(g_states[i].symbol==symbol)
         return i;
   return -1;
}


bool RiskAllows(string symbol,int direction,int idx,string &reason)
{
   UpdateRiskAnchors();

   string eq_reason="";
   if(!EquityLockAllows(eq_reason))
   {
      reason=eq_reason;
      return false;
   }

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double margin=AccountInfoDouble(ACCOUNT_MARGIN);

   double daily_dd_pct=0.0;
   if(g_day_start_equity>0.0) daily_dd_pct=((g_day_start_equity-equity)/g_day_start_equity)*100.0;

   double total_dd_pct=0.0;
   if(UseTrailingTotalDDFromPeak)
   {
      if(g_peak_equity>0.0) total_dd_pct=((g_peak_equity-equity)/g_peak_equity)*100.0;
   }
   else
   {
      if(g_initial_equity>0.0) total_dd_pct=((g_initial_equity-equity)/g_initial_equity)*100.0;
   }

   double margin_pct=0.0;
   if(balance>0.0) margin_pct=(margin/balance)*100.0;

   if(daily_dd_pct>=HardDailyDDPercent){ reason="HARD_DAILY_DD"; return false; }
   if(total_dd_pct>=HardTotalDDPercent){ reason="HARD_TOTAL_DD"; return false; }
   if(total_dd_pct>=PreventiveTotalDDPercent){ reason="PREVENTIVE_TOTAL_DD"; return false; }
   if(margin_pct>=MaxMarginUsagePercent){ reason="MARGIN_LIMIT"; return false; }
   if(CountOpenPositionsAll()>=MaxOpenPositions){ reason="MAX_POSITIONS"; return false; }
   if(g_total_trades_today>=MaxTradesPerDay){ reason="MAX_TRADES_PER_DAY"; return false; }
   if(g_states[idx].trades_today>=MaxTradesPerSymbolPerDay){ reason="MAX_TRADES_SYMBOL_DAY"; return false; }
   if(HasPositionSameSymbol(symbol)){ reason="ONE_POSITION_PER_SYMBOL"; return false; }
   if(AntiHedgePerSymbol && HasOppositePosition(symbol,direction)){ reason="ANTI_HEDGE_BLOCK"; return false; }

   reason="RISK_ALLOW";
   return true;
}


// ==================================================================
// PROFESSIONAL EXIT HELPERS
// ==================================================================
double PositionInitialRiskPrice(string symbol, long type, double open_price, double sl)
{
   if(sl <= 0.0 || open_price <= 0.0)
      return 0.0;

   if(type == POSITION_TYPE_BUY)
      return open_price - sl;

   if(type == POSITION_TYPE_SELL)
      return sl - open_price;

   return 0.0;
}

double CurrentRMultiple(string symbol, long type, double open_price, double sl)
{
   double risk = PositionInitialRiskPrice(symbol, type, open_price, sl);
   if(risk <= 0.0)
      return 0.0;

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double current = (type == POSITION_TYPE_BUY ? bid : ask);

   double profit_distance = 0.0;
   if(type == POSITION_TYPE_BUY)
      profit_distance = current - open_price;
   else
      profit_distance = open_price - current;

   return profit_distance / risk;
}

bool ModifyPositionStops(string symbol, double new_sl, double new_tp)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(new_sl > 0.0) new_sl = NormalizeDouble(new_sl, digits);
   if(new_tp > 0.0) new_tp = NormalizeDouble(new_tp, digits);

   trade.SetExpertMagicNumber(MagicNumber);
   return trade.PositionModify(symbol, new_sl, new_tp);
}

bool ShouldExitByWeakness(MarketContext &ctx, int direction)
{
   if(!UseWeaknessExit)
      return false;

   double expansion = direction > 0 ? ctx.expansion_buy : ctx.expansion_sell;
   double follow    = direction > 0 ? ctx.follow_buy : ctx.follow_sell;
   double wick      = direction > 0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection = direction > 0 ? ctx.rejection_buy : ctx.rejection_sell;

   if(expansion <= ExpansionDecayMax)
      return true;

   if(follow <= FollowDecayMax)
      return true;

   if(wick >= WickExitRiskMin)
      return true;

   if(rejection >= WickExitRiskMin)
      return true;

   return false;
}

int FindSymbolIndex(string symbol)
{
   for(int i=0; i<ArraySize(g_states); i++)
      if(g_states[i].symbol == symbol)
         return i;
   return -1;
}


// ==================================================================
// LOT AND EXECUTION
// ==================================================================
double SymbolLotCap(string symbol)
{
   double cap = MaxLotDefault;

   if(StartsWith(symbol,"XAU"))
      cap = MaxLotXAU;
   else if(StartsWith(symbol,"US500"))
      cap = MaxLotUS500;
   else if(StartsWith(symbol,"GER40"))
      cap = MaxLotGER40;
   else if(StartsWith(symbol,"US100"))
      cap = MaxLotUS100;

   cap = MathMin(cap, MaxLot);
   return cap;
}

double MarginSafeVolume(string symbol, int direction, double lots, double price)
{
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0) step = 0.01;
   if(vmin <= 0.0) vmin = MinLot;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin_now = AccountInfoDouble(ACCOUNT_MARGIN);
   double max_margin_allowed = equity * MaxMarginUsagePercent / 100.0;
   double remaining_margin = max_margin_allowed - margin_now;

   if(remaining_margin <= 0.0)
      return 0.0;

   ENUM_ORDER_TYPE order_type = direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double test_margin = 0.0;
   if(!OrderCalcMargin(order_type, symbol, lots, price, test_margin))
      return lots;

   if(test_margin <= remaining_margin)
      return lots;

   double adjusted = lots;
   while(adjusted >= vmin)
   {
      adjusted -= step;
      adjusted = MathFloor(adjusted / step) * step;
      if(adjusted < vmin) break;

      test_margin = 0.0;
      if(!OrderCalcMargin(order_type, symbol, adjusted, price, test_margin))
         return adjusted;

      if(test_margin <= remaining_margin)
         return adjusted;
   }

   return 0.0;
}

double NormalizeVolume(string symbol,double lots)
{
   double vmin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(vmin<=0.0) vmin=MinLot;
   if(vmax<=0.0) vmax=MaxLot;
   if(step<=0.0) step=0.01;
   lots=MathMax(lots,vmin);
   lots=MathMin(lots,vmax);
   double symbol_cap = SymbolLotCap(symbol);
   lots=MathMax(lots,MinLot);
   lots=MathMin(lots,symbol_cap);
   lots=MathFloor(lots/step)*step;
   int digits=2;
   if(step<0.01) digits=3;
   if(step<0.001) digits=4;
   return NormalizeDouble(lots,digits);
}

double CalculateRiskLot(string symbol,double sl_distance_price)
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money=equity*RiskPerTradePercent/100.0;
   double tick_size=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tick_size<=0.0 || tick_value<=0.0 || sl_distance_price<=0.0)
      return NormalizeVolume(symbol,MinLot);
   double loss_per_lot=(sl_distance_price/tick_size)*tick_value;
   if(loss_per_lot<=0.0) return NormalizeVolume(symbol,MinLot);
   double lots=risk_money/loss_per_lot;
   return NormalizeVolume(symbol,lots);
}

bool IsIndexSymbol(string symbol)
{
   return StartsWith(symbol,"US500") || StartsWith(symbol,"US100") || StartsWith(symbol,"GER40");
}

bool IsGoldSymbol(string symbol)
{
   return StartsWith(symbol,"XAU") || StringFind(symbol,"GOLD",0)>=0;
}

double AssetBehaviorAdjustment(MarketContext &ctx, int direction)
{
   if(!UseAssetBehaviorReader)
      return 0.0;

   bool is_index = IsIndexSymbol(ctx.symbol);
   double expansion  = direction>0?ctx.expansion_buy:ctx.expansion_sell;
   double acceptance = direction>0?ctx.acceptance_buy:ctx.acceptance_sell;
   double follow     = direction>0?ctx.follow_buy:ctx.follow_sell;
   double wick       = direction>0?ctx.wick_risk_buy:ctx.wick_risk_sell;
   double align      = direction>0?ctx.direction_alignment_buy:ctx.direction_alignment_sell;

   double bonus = 0.0;

   if(is_index)
   {
      // Index language: strong expansion + clear acceptance + low rejection,
      // even with follow around 0.50-0.55.
      if(expansion>=0.72 && acceptance>=0.68 && follow>=IndexFollowSoftFloor && wick<=0.34)
         bonus += IndexLateAcceptanceBonus;

      if(align>=0.66 && acceptance>=0.72 && ctx.liquidity_quality>=IndexLiquidityMin)
         bonus += 2.0;

      if(ctx.spread_quality>=0.45 && wick<=0.30)
         bonus += 1.5;
   }
   else
   {
      // Gold needs liquidity and cleaner follow because it already produces enough opportunities.
      if(acceptance>=0.76 && follow>=GoldFollowSoftFloor && ctx.liquidity_quality>=GoldLiquidityMin)
         bonus += 2.0;
   }

   return bonus;
}


double AdaptiveTransitionScore(MarketContext &ctx,int direction)
{
   double expansion  = direction>0?ctx.expansion_buy:ctx.expansion_sell;
   double acceptance = direction>0?ctx.acceptance_buy:ctx.acceptance_sell;
   double follow     = direction>0?ctx.follow_buy:ctx.follow_sell;
   double wick       = direction>0?ctx.wick_risk_buy:ctx.wick_risk_sell;
   double align      = direction>0?ctx.direction_alignment_buy:ctx.direction_alignment_sell;
   double strength   = direction>0?ctx.strength_buy:ctx.strength_sell;
   double room       = direction>0?ctx.volatility_room_buy:ctx.volatility_room_sell;

   // The indices do not confirm like gold. This score reads "sufficient acceptance",
   // not perfect follow-through.
   double score =
      expansion                 * 22.0 +
      acceptance                * 24.0 +
      follow                    * 10.0 +
      (1.0 - wick)              * 14.0 +
      align                     * 12.0 +
      strength                  * 8.0  +
      Clamp01(room)             * 4.0  +
      ctx.liquidity_quality     * 3.0  +
      ctx.spread_quality        * 3.0;

   score += AssetBehaviorAdjustment(ctx,direction);

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

bool SoftAcceptancePass(double expansion,double acceptance,double follow,double wick,double align,DriverThresholds &d)
{
   // Full pass.
   if(acceptance>=d.acceptance_min && follow>=d.follow_min && wick<=d.wick_max && align>=d.direction_align_min)
      return true;

   // Strong impulse + high acceptance: valid for indices when follow is imperfect.
   if(expansion>=d.expansion_min+0.08 &&
      acceptance>=d.acceptance_min+0.08 &&
      follow>=IndexFollowSoftFloor &&
      wick<=d.wick_max &&
      align>=d.direction_align_min-0.10)
      return true;

   // Retest-style acceptance: price accepts, rejection is controlled, follow not beautiful.
   if(acceptance>=d.acceptance_min+0.12 &&
      follow>=IndexFollowSoftFloor &&
      wick<=d.wick_max-0.03 &&
      align>=d.direction_align_min-0.12)
      return true;

   return false;
}


double ProfitDefenseGivebackMoney()
{
   if(!EnableProfitDefenseEngine)
      return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      return 0.0;

   double peak_profit = g_peak_equity - g_initial_equity;
   if(peak_profit < ProfitDefenseActivationMoney)
      return 0.0;

   double giveback = g_peak_equity - equity;
   if(giveback < 0.0) giveback = 0.0;
   return giveback;
}

bool ProfitDefenseSoftActive()
{
   return ProfitDefenseGivebackMoney() >= ProfitDefenseSoftGivebackMoney;
}

bool ProfitDefenseHardActive()
{
   return ProfitDefenseGivebackMoney() >= ProfitDefenseHardGivebackMoney;
}

double ProfitDefenseRiskFactor()
{
   if(!EnableProfitDefenseEngine)
      return 1.0;

   if(ProfitDefenseHardActive())
      return MathMax(0.10, MathMin(1.0, ProfitDefenseRiskFactorHard));

   if(ProfitDefenseSoftActive())
      return MathMax(0.10, MathMin(1.0, ProfitDefenseRiskFactorSoft));

   return 1.0;
}

double ProfitDefenseQualityAdd()
{
   if(!EnableProfitDefenseEngine)
      return 0.0;

   if(ProfitDefenseHardActive())
      return ProfitDefenseQualityAddHard;

   if(ProfitDefenseSoftActive())
      return ProfitDefenseQualityAddSoft;

   return 0.0;
}

double CurrentRiskMoney()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity * RiskPerTradePercent / 100.0;
   risk_money *= ProfitDefenseRiskFactor();
   return risk_money;
}

double ExpectedProfitMoneyByLot(string symbol,double tp_distance_price,double lots)
{
   double tick_size = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);

   if(tick_size <= 0.0 || tick_value <= 0.0 || tp_distance_price <= 0.0 || lots <= 0.0)
      return 0.0;

   return (tp_distance_price / tick_size) * tick_value * lots;
}



// ==================================================================
// ASSET REGIME ROUTER ENGINE V4.9
// ==================================================================
double DirectionConflictGap(MarketContext &ctx,int direction)
{
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double opposite_acceptance = direction>0 ? ctx.acceptance_sell : ctx.acceptance_buy;
   return MathMax(0.0, opposite_acceptance - acceptance);
}

MarketRegimeType DetectAssetRegime(MarketContext &ctx,int direction)
{
   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double strength   = direction>0 ? ctx.strength_buy : ctx.strength_sell;
   double conflict   = DirectionConflictGap(ctx,direction);

   // Rango/noise: mucho conflicto, baja continuidad o mecha excesiva.
   if((conflict>0.16 && follow<0.56) || (ctx.range_efficiency<0.12 && follow<0.52) || (wick>0.70 && rejection>0.60))
      return REGIME_RANGE;

   // Tendencia: dirección alineada, continuidad suficiente y bajo ruido.
   if(align>=0.62 && follow>=0.54 && acceptance>=0.56 && wick<=0.56 && conflict<=0.12)
      return REGIME_TREND;

   // Pullback: no es ruptura; es reanudación limpia tras retroceso controlado.
   if(align>=0.54 && acceptance>=0.58 && follow>=0.42 && wick<=0.58 && rejection<=0.66 && conflict<=0.14)
      return REGIME_PULLBACK;

   // Expansión: impulso fuerte, pero todavía debe validarse por activo.
   if(expansion>=0.64 && strength>=0.58 && follow>=0.46 && wick<=0.64)
      return REGIME_EXPANSION;

   return REGIME_UNDEFINED;
}

double AssetRegimeReadScore(MarketContext &ctx,int direction)
{
   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double strength   = direction>0 ? ctx.strength_buy : ctx.strength_sell;
   double conflict_gap = DirectionConflictGap(ctx,direction);

   double score = 0.0;

   if(IsGoldSymbol(ctx.symbol))
   {
      score += expansion * 16.0;
      score += acceptance * 18.0;
      score += follow * 15.0;
      score += (1.0-wick) * 15.0;
      score += (1.0-rejection) * 10.0;
      score += align * 10.0;
      score += ctx.liquidity_quality * 7.0;
      score += ctx.range_efficiency * 4.0;
      score += ctx.session_activity_score * 5.0;
   }
   else if(StartsWith(ctx.symbol,"US500"))
   {
      // V4.9: SP500 no debe tratarse como Oro. Se premia tendencia/pullback y no ruptura extrema.
      score += follow * 20.0;
      score += acceptance * 18.0;
      score += align * 16.0;
      score += ctx.range_efficiency * 14.0;
      score += (1.0-wick) * 14.0;
      score += strength * 8.0;
      score += ctx.session_activity_score * 5.0;
      score += (1.0-conflict_gap) * 5.0;
   }
   else if(StartsWith(ctx.symbol,"US100"))
   {
      score += expansion * 22.0;
      score += strength * 20.0;
      score += follow * 16.0;
      score += acceptance * 14.0;
      score += align * 12.0;
      score += (1.0-wick) * 8.0;
      score += ctx.range_efficiency * 4.0;
      score += (1.0-conflict_gap) * 4.0;
   }
   else if(StartsWith(ctx.symbol,"GER40"))
   {
      score += strength * 20.0;
      score += follow * 17.0;
      score += acceptance * 14.0;
      score += align * 14.0;
      score += (1.0-wick) * 13.0;
      score += ctx.session_activity_score * 10.0;
      score += (1.0-conflict_gap) * 8.0;
      score += expansion * 4.0;
   }
   else
   {
      score += expansion * 18.0 + acceptance * 18.0 + follow * 16.0 + (1.0-wick) * 14.0 + align * 12.0 + strength * 10.0 + ctx.range_efficiency * 6.0 + ctx.liquidity_quality * 6.0;
   }

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

double RequiredAssetRegimeScore(string symbol)
{
   if(IsGoldSymbol(symbol)) return MRCE_MinGoldRegimeScore;
   if(StartsWith(symbol,"US500")) return 64.0; // V4.8 bloqueó demasiado US500. V4.9 baja umbral, pero exige régimen correcto.
   if(StartsWith(symbol,"US100")) return MRCE_MinUS100RegimeScore;
   if(StartsWith(symbol,"GER40")) return MRCE_MinGER40RegimeScore;
   return 70.0;
}

// ==================================================================
// CONTROLLED PROFIT PROTECTION ENGINE V5.1
// ==================================================================
double CPPDrawdownPctFromPeak()
{
   if(g_peak_equity <= 0.0)
      return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = ((g_peak_equity - equity) / g_peak_equity) * 100.0;
   if(dd < 0.0) dd = 0.0;
   return dd;
}

ProfitProtectionState CurrentProfitProtectionState()
{
   if(!EnableControlledProfitProtection)
      return CPP_STATE_NORMAL;

   if(g_peak_equity <= 0.0 || g_initial_equity <= 0.0)
      return CPP_STATE_NORMAL;

   double peak_profit = g_peak_equity - g_initial_equity;
   if(peak_profit < CPP_ActivationProfitMoney)
      return CPP_STATE_NORMAL;

   double dd_pct = CPPDrawdownPctFromPeak();

   if(dd_pct >= CPP_DefensiveDrawdownPctFromPeak)
      return CPP_STATE_DEFENSIVE;

   if(dd_pct >= CPP_ProtectDrawdownPctFromPeak)
      return CPP_STATE_PROTECT;

   return CPP_STATE_NORMAL;
}

double CPPEntryQualityScore(MarketContext &ctx,int direction)
{
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double strength   = direction>0 ? ctx.strength_buy : ctx.strength_sell;

   double q = 0.0;
   q += acceptance * 20.0;
   q += follow * 20.0;
   q += align * 16.0;
   q += strength * 12.0;
   q += (1.0-wick) * 14.0;
   q += (1.0-rejection) * 8.0;
   q += ctx.range_efficiency * 5.0;
   q += ctx.liquidity_quality * 5.0;

   if(q<0.0) q=0.0;
   if(q>100.0) q=100.0;
   return q;
}

bool ControlledProfitProtectionPasses(MarketContext &ctx,int direction,string &reason)
{
   if(!EnableControlledProfitProtection)
   {
      reason="CPP_DISABLED";
      return true;
   }

   ProfitProtectionState state = CurrentProfitProtectionState();
   if(state==CPP_STATE_NORMAL)
   {
      reason="CPP_NORMAL";
      return true;
   }

   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double conflict   = DirectionConflictGap(ctx,direction);
   double quality    = CPPEntryQualityScore(ctx,direction);
   MarketRegimeType regime = DetectAssetRegime(ctx,direction);

   // Estado PROTECT: no bloquea el motor; solo elimina continuidad claramente floja.
   if(state==CPP_STATE_PROTECT)
   {
      double min_follow = ARRE_GlobalMinFollow + CPP_ProtectContinuityAdd;

      // US500 fue el avance de V4.9: mantenerlo vivo si está en tendencia/pullback válido.
      if(CPP_KeepUS500Alive && StartsWith(ctx.symbol,"US500"))
      {
         if((regime==REGIME_TREND || regime==REGIME_PULLBACK) && follow>=ARRE_US500_MinPullbackFollow && acceptance>=ARRE_US500_MinAcceptance && wick<=ARRE_US500_MaxWick)
         {
            reason="CPP_PROTECT_US500_ALIVE";
            return true;
         }
      }

      if(follow < min_follow && acceptance < 0.64)
      {
         reason="CPP_PROTECT_WEAK_CONTINUITY";
         return false;
      }

      reason="CPP_PROTECT_ALLOW";
      return true;
   }

   // Estado DEFENSIVE: más selectivo, pero no tipo V5.0. No exige esperas nuevas ni compresión perfecta.
   if(state==CPP_STATE_DEFENSIVE)
   {
      if(CPP_BlockGER40InDefensive && StartsWith(ctx.symbol,"GER40"))
      {
         reason="CPP_DEFENSIVE_BLOCK_GER40";
         return false;
      }

      double required_quality = RequiredAssetRegimeScore(ctx.symbol) + CPP_DefensiveQualityAdd;

      if(IsGoldSymbol(ctx.symbol))
      {
         // Oro sigue siendo líder: solo bloquear agotamiento/rechazo evidente.
         double expansion = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
         double decay = ExpansionDecayScore(ctx,direction);
         if(expansion>=Gold_MaxLateExpansion && decay>ARRE_Gold_MaxExhaustion && follow<Gold_MinFreshFollow)
         {
            reason="CPP_DEFENSIVE_GOLD_EXHAUSTED";
            return false;
         }
         required_quality -= 2.0;
      }
      else if(StartsWith(ctx.symbol,"US500"))
      {
         if(regime!=REGIME_TREND && regime!=REGIME_PULLBACK)
         {
            reason="CPP_DEFENSIVE_US500_BAD_REGIME";
            return false;
         }
         required_quality -= 1.5;
      }
      else if(StartsWith(ctx.symbol,"US100"))
      {
         required_quality += 1.0;
      }

      if(conflict>ARRE_GlobalMaxConflictGap || (wick>ARRE_GlobalMaxWickRisk && follow<0.58))
      {
         reason="CPP_DEFENSIVE_NOISY_CONTEXT";
         return false;
      }

      if(quality < required_quality)
      {
         reason="CPP_DEFENSIVE_QUALITY_LOW";
         return false;
      }

      if(align<0.54 && acceptance<0.64)
      {
         reason="CPP_DEFENSIVE_NO_DIRECTION_ACCEPTANCE";
         return false;
      }

      reason="CPP_DEFENSIVE_ALLOW";
      return true;
   }

   reason="CPP_ALLOW";
   return true;
}

bool AssetRegimeRouterPasses(MarketContext &ctx,int direction,string &reason)
{
   if(!EnableAssetRegimeRouterEngine)
   {
      reason="ARRE_DISABLED";
      return true;
   }

   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double strength   = direction>0 ? ctx.strength_buy : ctx.strength_sell;
   double conflict   = DirectionConflictGap(ctx,direction);
   MarketRegimeType regime = DetectAssetRegime(ctx,direction);

   if(wick>ARRE_GlobalMaxWickRisk && follow<0.58)
   {
      reason="ARRE_GLOBAL_WICK_NO_FOLLOW_"+MarketRegimeName(regime);
      return false;
   }
   if(follow<ARRE_GlobalMinFollow && acceptance<0.62)
   {
      reason="ARRE_GLOBAL_NO_CONTINUITY_"+MarketRegimeName(regime);
      return false;
   }
   if(conflict>ARRE_GlobalMaxConflictGap)
   {
      reason="ARRE_GLOBAL_DIRECTION_CONFLICT_"+MarketRegimeName(regime);
      return false;
   }

   if(IsGoldSymbol(ctx.symbol))
   {
      if(regime==REGIME_RANGE || regime==REGIME_UNDEFINED)
      {
         reason="ARRE_GOLD_BAD_REGIME_"+MarketRegimeName(regime);
         return false;
      }
      double life  = ExpansionLifecycleScore(ctx,direction);
      double decay = ExpansionDecayScore(ctx,direction);
      if(expansion>=Gold_MaxLateExpansion && decay>ARRE_Gold_MaxExhaustion && life<MRCE_Gold_MinLifeWhenExtended)
      {
         reason="ARRE_GOLD_EXTENDED_EXHAUSTION";
         return false;
      }
      if(wick>ARRE_Gold_MaxWick && rejection>0.58 && follow<0.58)
      {
         reason="ARRE_GOLD_REJECTION_TRAP";
         return false;
      }
      if(conflict>ARRE_Gold_MaxConflictGap && align<0.62)
      {
         reason="ARRE_GOLD_CONFLICT";
         return false;
      }
      reason="ARRE_GOLD_"+MarketRegimeName(regime)+"_OK";
      return true;
   }

   if(StartsWith(ctx.symbol,"US500"))
   {
      // SP500: no ruptura bruta; se permite tendencia y pullback con reanudación.
      bool trend_ok = (regime==REGIME_TREND && follow>=ARRE_US500_MinTrendFollow && acceptance>=ARRE_US500_MinAcceptance && align>=US500_MinAlignment-0.04 && wick<=ARRE_US500_MaxWick && conflict<=ARRE_US500_MaxConflictGap && ctx.range_efficiency>=ARRE_US500_MinRangeEfficiency);
      bool pullback_ok = (regime==REGIME_PULLBACK && follow>=ARRE_US500_MinPullbackFollow && acceptance>=ARRE_US500_MinAcceptance+0.02 && align>=US500_MinAlignment-0.08 && wick<=ARRE_US500_MaxWick && conflict<=ARRE_US500_MaxConflictGap && rejection<=0.66);

      if(!(trend_ok || pullback_ok))
      {
         reason="ARRE_US500_NOT_TREND_OR_PULLBACK_"+MarketRegimeName(regime);
         return false;
      }
      reason="ARRE_US500_"+MarketRegimeName(regime)+"_OK";
      return true;
   }

   if(StartsWith(ctx.symbol,"US100"))
   {
      double momentum = expansion*0.35 + strength*0.30 + follow*0.20 + align*0.15;
      bool strong_trend = (regime==REGIME_TREND && strength>=ARRE_US100_MinTrendStrength && follow>=US100_MinFollow && conflict<=ARRE_US100_MaxConflictGap);
      bool strong_expansion = (regime==REGIME_EXPANSION && momentum>=ARRE_US100_MinMomentum && align>=0.60 && wick<=US100_MaxWickRisk);
      if(!(strong_trend || strong_expansion))
      {
         reason="ARRE_US100_NO_STRONG_MOMENTUM_"+MarketRegimeName(regime);
         return false;
      }
      reason="ARRE_US100_"+MarketRegimeName(regime)+"_OK";
      return true;
   }

   if(StartsWith(ctx.symbol,"GER40"))
   {
      if(ctx.hour_server < GER40_TimingStartHour || ctx.hour_server >= GER40_TimingEndHour)
      {
         reason="ARRE_GER40_OUTSIDE_EUROPE_CORE";
         return false;
      }
      if(regime!=REGIME_TREND || strength<ARRE_GER40_MinTrendStrength || wick>ARRE_GER40_MaxWick || conflict>ARRE_GER40_MaxConflictGap || align<0.68)
      {
         reason="ARRE_GER40_NOT_CLEAR_TREND_"+MarketRegimeName(regime);
         return false;
      }
      reason="ARRE_GER40_CLEAR_TREND_OK";
      return true;
   }

   if(regime==REGIME_RANGE || regime==REGIME_UNDEFINED)
   {
      reason="ARRE_DEFAULT_BAD_REGIME_"+MarketRegimeName(regime);
      return false;
   }

   reason="ARRE_DEFAULT_"+MarketRegimeName(regime)+"_OK";
   return true;
}

bool MarketReadConfirmationPasses(MarketContext &ctx,int direction,string &reason)
{
   if(!EnableMarketReadConfirmationEngine)
   {
      reason="MRCE_DISABLED";
      return true;
   }

   double regime_score = AssetRegimeReadScore(ctx,direction);

   if(regime_score < RequiredAssetRegimeScore(ctx.symbol))
   {
      reason="MRCE_REGIME_SCORE_LOW";
      return false;
   }

   string router_reason="";
   if(!AssetRegimeRouterPasses(ctx,direction,router_reason))
   {
      reason=router_reason;
      return false;
   }

   reason="MRCE_ARRE_OK";
   return true;
}

bool FinalEntryPasses(MarketContext &ctx,int direction,DriverThresholds &d,string &reason)
{
   double expansion=direction>0?ctx.expansion_buy:ctx.expansion_sell;
   double acceptance=direction>0?ctx.acceptance_buy:ctx.acceptance_sell;
   double follow=direction>0?ctx.follow_buy:ctx.follow_sell;
   double wick=direction>0?ctx.wick_risk_buy:ctx.wick_risk_sell;
   double align=direction>0?ctx.direction_alignment_buy:ctx.direction_alignment_sell;
   double raw_score=direction>0?ctx.score_buy:ctx.score_sell;
   double transition_score=AdaptiveTransitionScore(ctx,direction);

   if(ctx.hour_server<d.start_hour || ctx.hour_server>=d.end_hour){ reason="SESSION_BLOCK"; return false; }

   string mrce_reason="";
   if(!MarketReadConfirmationPasses(ctx,direction,mrce_reason))
   {
      reason=mrce_reason;
      return false;
   }

   string cpp_reason="";
   if(!ControlledProfitProtectionPasses(ctx,direction,cpp_reason))
   {
      reason=cpp_reason;
      return false;
   }

   if(expansion<d.expansion_min){ reason="EXPANSION_LOW"; return false; }

   if(!SoftAcceptancePass(expansion,acceptance,follow,wick,align,d))
   {
      reason="SOFT_ACCEPTANCE_FAIL";
      return false;
   }

   string timing_reason="";
   if(!AssetAdaptiveTimingPasses(ctx,direction,timing_reason))
   {
      reason=timing_reason;
      return false;
   }

   if(transition_score<d.score_min)
   {
      reason="TRANSITION_SCORE_LOW";
      return false;
   }

   // The old score is no longer a hard gate. It is only a sanity check at very low values.
   if(raw_score < d.score_min-12.0)
   {
      reason="RAW_SCORE_TOO_WEAK";
      return false;
   }

   double point=SymbolInfoDouble(ctx.symbol,SYMBOL_POINT);
   if(point<=0.0) point=0.00001;
   double spread_to_atr=0.0;
   if(ctx.atr_now>0.0) spread_to_atr=((ctx.spread_points*point)/ctx.atr_now)*100.0;
   if(spread_to_atr>MaxSpreadToATRPercent){ reason="SPREAD_HIGH"; return false; }

   reason="ADAPTIVE_CONTEXT_ALLOW";
   return true;
}



// ==================================================================
// MARKET UNDERSTANDING ENGINE V4.0
// ==================================================================
double MarketCleanContextScore(MarketContext &ctx,int direction)
{
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double room       = direction>0 ? ctx.volatility_room_buy : ctx.volatility_room_sell;

   double score = 0.0;
   score += acceptance * 22.0;
   score += follow * 18.0;
   score += (1.0-wick) * 16.0;
   score += (1.0-rejection) * 12.0;
   score += align * 12.0;
   score += ctx.liquidity_quality * 8.0;
   score += ctx.spread_quality * 6.0;
   score += Clamp01(room) * 6.0;

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

double FalseExpansionRisk(MarketContext &ctx,int direction)
{
   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double opposite_acceptance = direction>0 ? ctx.acceptance_sell : ctx.acceptance_buy;

   double risk = 0.0;
   risk += wick * 22.0;
   risk += rejection * 20.0;
   risk += (1.0-follow) * 18.0;
   risk += (1.0-acceptance) * 14.0;
   risk += (1.0-align) * 12.0;
   risk += MathMax(0.0, opposite_acceptance-acceptance) * 10.0;
   risk += (1.0-expansion) * 4.0;

   if(risk<0.0) risk=0.0;
   if(risk>100.0) risk=100.0;
   return risk;
}

double ImpulseFreshnessScore(MarketContext &ctx,int direction)
{
   double expansion = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double follow    = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double strength  = direction>0 ? ctx.strength_buy : ctx.strength_sell;
   double candle    = direction>0 ? ctx.candle_power_buy : ctx.candle_power_sell;
   double wick      = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;

   double score = 0.0;
   score += expansion * 28.0;
   score += follow * 22.0;
   score += strength * 20.0;
   score += candle * 16.0;
   score += (1.0-wick) * 14.0;

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

double DirectionConflictScore(MarketContext &ctx,int direction)
{
   double buy_core  = ctx.acceptance_buy*0.40 + ctx.follow_buy*0.25 + ctx.expansion_buy*0.20 + ctx.structure_direction_buy*0.15;
   double sell_core = ctx.acceptance_sell*0.40 + ctx.follow_sell*0.25 + ctx.expansion_sell*0.20 + ctx.structure_direction_sell*0.15;

   if(direction>0)
      return Clamp01(sell_core - buy_core + 0.50);

   return Clamp01(buy_core - sell_core + 0.50);
}


double RequiredMUESurvivalScore(string symbol)
{
   double required = MUE_MinSurvivalScore;
   if(!EnableAssetAdaptiveTimingEngine)
      return required;

   if(IsGoldSymbol(symbol))
      required = MathMax(required, 72.0);
   else if(StartsWith(symbol,"US500"))
      required = 68.0;
   else if(StartsWith(symbol,"US100"))
      required = 69.0;
   else if(StartsWith(symbol,"GER40"))
      required = 74.0;

   return required;
}

double RequiredMUECleanContext(string symbol)
{
   double required = MUE_MinCleanContext;
   if(!EnableAssetAdaptiveTimingEngine)
      return required;

   if(StartsWith(symbol,"US500"))
      required = 61.0;
   else if(StartsWith(symbol,"US100"))
      required = 64.0;
   else if(StartsWith(symbol,"GER40"))
      required = 69.0;

   return required;
}

double AllowedMUEFalseExpansionRisk(string symbol)
{
   double allowed = MUE_MaxFalseExpansionRisk;
   if(!EnableAssetAdaptiveTimingEngine)
      return allowed;

   if(IsGoldSymbol(symbol))
      allowed = 44.0;
   else if(StartsWith(symbol,"US500"))
      allowed = 48.0;
   else if(StartsWith(symbol,"US100"))
      allowed = 46.0;
   else if(StartsWith(symbol,"GER40"))
      allowed = 38.0;

   return allowed;
}

double RequiredMUEImpulseFreshness(string symbol)
{
   double required = MUE_MinImpulseFreshness;
   if(!EnableAssetAdaptiveTimingEngine)
      return required;

   if(StartsWith(symbol,"US500"))
      required = 52.0;
   else if(StartsWith(symbol,"US100"))
      required = 58.0;
   else if(StartsWith(symbol,"GER40"))
      required = 60.0;

   return required;
}

double AllowedMUEDecisionConflict(string symbol)
{
   double allowed = MUE_MaxDecisionConflict;
   if(!EnableAssetAdaptiveTimingEngine)
      return allowed;

   if(StartsWith(symbol,"US500"))
      allowed = 0.34;
   else if(StartsWith(symbol,"US100"))
      allowed = US100_MaxTimingConflict;
   else if(StartsWith(symbol,"GER40"))
      allowed = GER40_MaxTimingConflict;

   return allowed;
}

bool AssetAdaptiveTimingPasses(MarketContext &ctx,int direction,string &reason)
{
   if(!EnableAssetAdaptiveTimingEngine)
   {
      reason="ASSET_ADAPTIVE_TIMING_DISABLED";
      return true;
   }

   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double strength   = direction>0 ? ctx.strength_buy : ctx.strength_sell;
   double opposite_acceptance = direction>0 ? ctx.acceptance_sell : ctx.acceptance_buy;
   double conflict_gap = opposite_acceptance - acceptance;

   if(IsGoldSymbol(ctx.symbol))
   {
      // Oro: evitar entrar cuando el movimiento ya está extendido y empieza a mostrar rechazo.
      if(expansion >= Gold_MaxLateExpansion && follow < Gold_MinFreshFollow && wick > Gold_MaxTimingWickRisk)
      {
         reason="AAT_GOLD_LATE_EXHAUSTED_MOVE";
         return false;
      }
      if(wick > Gold_MaxTimingWickRisk+0.08 && rejection > 0.58)
      {
         reason="AAT_GOLD_WICK_REJECTION_TRAP";
         return false;
      }
      reason="AAT_GOLD_ALLOW";
      return true;
   }

   if(StartsWith(ctx.symbol,"US500"))
   {
      // V4.9: el router ya decide régimen. Aquí solo evitamos timing claramente sucio.
      bool clean_continuation = (follow>=US500_MinFollow && acceptance>=US500_MinAcceptance && wick<=US500_MaxWickRisk && align>=US500_MinAlignment-0.06 && ctx.range_efficiency>=US500_MinRangeEfficiency-0.08);
      bool healthy_pullback   = (acceptance>=US500_MinAcceptance+0.02 && follow>=0.42 && wick<=US500_MaxWickRisk && conflict_gap<=US500_MaxOppAcceptanceGap+0.03 && align>=US500_MinAlignment-0.10);

      if(!(clean_continuation || healthy_pullback))
      {
         reason="AAT_US500_NO_RESTART_TIMING";
         return false;
      }
      reason="AAT_US500_ALLOW";
      return true;
   }

   if(StartsWith(ctx.symbol,"US100"))
   {
      // NASDAQ: operar menos, pero con momentum verdadero.
      if(expansion < US100_MinMomentumExpansion || strength < US100_MinStrength)
      {
         reason="AAT_US100_MOMENTUM_NOT_ENOUGH";
         return false;
      }
      if(conflict_gap > 0.10 && align < 0.62)
      {
         reason="AAT_US100_DIRECTION_CONFLICT";
         return false;
      }
      reason="AAT_US100_ALLOW";
      return true;
   }

   if(StartsWith(ctx.symbol,"GER40"))
   {
      // DAX: solo sesión europea limpia, fuerza real y muy poco conflicto.
      if(ctx.hour_server < GER40_TimingStartHour || ctx.hour_server >= GER40_TimingEndHour)
      {
         reason="AAT_GER40_OUTSIDE_CORE_SESSION";
         return false;
      }
      if(strength < GER40_MinTimingStrength || wick > GER40_MaxWickRisk || conflict_gap > 0.06 || align < 0.66)
      {
         reason="AAT_GER40_NOT_CLEAR_ENOUGH";
         return false;
      }
      reason="AAT_GER40_ALLOW";
      return true;
   }

   reason="AAT_DEFAULT_ALLOW";
   return true;
}

bool MarketUnderstandingPasses(MarketContext &ctx,int direction,string &reason)
{
   if(!UseMarketUnderstandingEngine)
   {
      reason="MUE_DISABLED";
      return true;
   }

   double survival = SelectorQualityScore(ctx,direction);
   double clean    = MarketCleanContextScore(ctx,direction);
   double falseExp = FalseExpansionRisk(ctx,direction);
   double fresh    = ImpulseFreshnessScore(ctx,direction);
   double conflict = DirectionConflictScore(ctx,direction);
   double decay    = ExpansionDecayScore(ctx,direction);
   double life     = ExpansionLifecycleScore(ctx,direction);

   if(falseExp > AllowedMUEFalseExpansionRisk(ctx.symbol))
   {
      reason="MUE_FALSE_EXPANSION_RISK";
      return false;
   }

   if(clean < RequiredMUECleanContext(ctx.symbol))
   {
      reason="MUE_CONTEXT_NOT_CLEAN";
      return false;
   }

   if(fresh < RequiredMUEImpulseFreshness(ctx.symbol))
   {
      reason="MUE_IMPULSE_NOT_FRESH";
      return false;
   }

   if(conflict > AllowedMUEDecisionConflict(ctx.symbol))
   {
      reason="MUE_DIRECTION_CONFLICT";
      return false;
   }

   if(survival < RequiredMUESurvivalScore(ctx.symbol))
   {
      reason="MUE_SURVIVAL_SCORE_LOW";
      return false;
   }

   if(decay >= LifecycleDecayExitScore && life < 72.0)
   {
      reason="MUE_EXPANSION_ALREADY_DECAYING";
      return false;
   }

   reason="MUE_MARKET_UNDERSTANDING_ALLOW";
   return true;
}


// ==================================================================
// TRADE SURVIVAL INTELLIGENCE V4.4
// ==================================================================
double RequiredTradeSurvivalScore(string symbol,int idx)
{
   double required = TradeSurvivalMinScore;

   if(EnableAssetSpecificEngine)
   {
      if(IsGoldSymbol(symbol))
         required = SurvivalGold;
      else if(StartsWith(symbol,"US500"))
         required = SurvivalUS500;
      else if(StartsWith(symbol,"US100"))
         required = SurvivalUS100;
      else if(StartsWith(symbol,"GER40"))
         required = SurvivalGER40;
      else if(IsIndexSymbol(symbol))
         required = TradeSurvivalMinScoreIndex;
   }
   else
   {
      if(IsGoldSymbol(symbol))
         required = TradeSurvivalMinScoreGold;
      else if(StartsWith(symbol,"US500"))
         required = MathMax(TradeSurvivalMinScoreUS500, IndexAPlusMinSurvival + 4.0);
      else if(IsIndexSymbol(symbol))
         required = MathMax(TradeSurvivalMinScoreIndex, IndexAPlusMinSurvival);
   }

   if(EnableProfitDefenseEngine)
   {
      if(ProfitDefenseHardActive())
         required += TradeSurvivalDefenseAddHard;
      else if(ProfitDefenseSoftActive())
         required += TradeSurvivalDefenseAddSoft;
   }

   if(idx>=0 && idx<ArraySize(g_states))
      required += (double)g_states[idx].consecutive_losses * TradeSurvivalConsecutiveLossAdd;

   if(required<0.0) required=0.0;
   if(required>95.0) required=95.0;
   return required;
}

double AllowedImmediateDeathRisk(string symbol)
{
   if(IsGoldSymbol(symbol))
      return TradeSurvivalMaxImmediateDeathRiskGold;
   if(StartsWith(symbol,"US500"))
      return TradeSurvivalMaxImmediateDeathRiskUS500;
   if(IsIndexSymbol(symbol))
      return TradeSurvivalMaxImmediateDeathRiskIndex;
   return TradeSurvivalMaxImmediateDeathRisk;
}

double ImmediateDeathRiskScore(MarketContext &ctx,int direction)
{
   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double candle     = direction>0 ? ctx.candle_power_buy : ctx.candle_power_sell;
   double opposite_acceptance = direction>0 ? ctx.acceptance_sell : ctx.acceptance_buy;
   double opposite_follow     = direction>0 ? ctx.follow_sell : ctx.follow_buy;

   double risk = 0.0;
   risk += wick * 24.0;
   risk += rejection * 22.0;
   risk += MathMax(0.0, opposite_acceptance-acceptance) * 16.0;
   risk += MathMax(0.0, opposite_follow-follow) * 12.0;
   risk += (1.0-follow) * 10.0;
   risk += (1.0-align) * 8.0;
   risk += (1.0-candle) * 5.0;
   risk += (1.0-expansion) * 3.0;

   if(risk<0.0) risk=0.0;
   if(risk>100.0) risk=100.0;
   return risk;
}

double TradeSurvivalScore(MarketContext &ctx,int direction,int idx)
{
   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double strength   = direction>0 ? ctx.strength_buy : ctx.strength_sell;
   double candle     = direction>0 ? ctx.candle_power_buy : ctx.candle_power_sell;
   double room       = direction>0 ? ctx.volatility_room_buy : ctx.volatility_room_sell;

   double transition = AdaptiveTransitionScore(ctx,direction);
   double clean      = MarketCleanContextScore(ctx,direction);
   double fresh      = ImpulseFreshnessScore(ctx,direction);
   double false_exp  = FalseExpansionRisk(ctx,direction);
   double death      = ImmediateDeathRiskScore(ctx,direction);
   double life       = ExpansionLifecycleScore(ctx,direction);
   double decay      = ExpansionDecayScore(ctx,direction);

   // Probabilidad de sobrevivir el primer tramo. No reemplaza a la señal; la valida.
   double score = 0.0;
   score += transition * 0.18;
   score += clean      * 0.17;
   score += fresh      * 0.12;
   score += life       * 0.10;
   score += expansion  * 9.0;
   score += acceptance * 9.0;
   score += follow     * 8.0;
   score += align      * 7.0;
   score += strength   * 5.0;
   score += candle     * 4.0;
   score += Clamp01(room) * 3.0;
   score += ctx.liquidity_quality * 4.0;
   score += ctx.spread_quality * 3.0;

   score -= wick * 5.0;
   score -= rejection * 5.0;
   score -= false_exp * 0.08;
   score -= death * 0.10;
   score -= decay * 0.05;

   // Penalización suave por activo con pérdidas recientes. No apaga; exige más claridad.
   if(idx>=0 && idx<ArraySize(g_states))
      score -= (double)g_states[idx].consecutive_losses * 2.0;

   // V4.5: rol por activo basado en lectura verificada del CSV.
   // XAUUSD fue el motor real: se le permite respirar cuando la aceptación es limpia.
   if(IsGoldSymbol(ctx.symbol) && follow>=GoldFollowSoftFloor && acceptance>=0.60 && wick<=0.52)
      score += AssetRoleGoldBonus;

   // V4.6: no penalizar todos los índices con la misma regla.
   // Cada índice tiene un idioma distinto:
   // US500 = continuidad institucional limpia, no necesariamente explosiva.
   // US100 = momentum fuerte, acepta más volatilidad si hay fuerza.
   // GER40 = impulso europeo con sesión y follow-through.
   if(EnableAssetSpecificEngine)
   {
      if(StartsWith(ctx.symbol,"US500"))
      {
         if(follow>=US500_MinFollow && acceptance>=US500_MinAcceptance && align>=US500_MinAlignment && wick<=US500_MaxWickRisk)
            score += 3.0;
         else
            score -= 2.0;
      }
      else if(StartsWith(ctx.symbol,"US100"))
      {
         if(follow>=US100_MinFollow && acceptance>=US100_MinAcceptance && strength>=US100_MinStrength)
            score += 2.0;
         else
            score -= 3.0;
      }
      else if(StartsWith(ctx.symbol,"GER40"))
      {
         if(follow>=GER40_MinFollow && acceptance>=GER40_MinAcceptance && ctx.session_activity_score>=GER40_MinSessionActivity)
            score += 2.0;
         else
            score -= 3.0;
      }
      else if(IsIndexSymbol(ctx.symbol))
         score -= 1.0;
   }
   else
   {
      // V4.5 legacy: all indices needed A+.
      if(IsIndexSymbol(ctx.symbol))
      {
         score -= AssetRoleIndexPenalty;
         if(follow<IndexAPlusMinFollow)
            score -= 4.0;
         if(acceptance<IndexAPlusMinAcceptance)
            score -= 3.0;
      }

      if(StartsWith(ctx.symbol,"US500"))
         score -= AssetRoleUS500Penalty;
   }

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

bool AssetRolePasses(MarketContext &ctx,int direction,string &reason,double survival_score)
{
   if(!EnableAssetRoleEngine)
   {
      reason="ASSET_ROLE_DISABLED";
      return true;
   }

   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double strength   = direction>0 ? ctx.strength_buy : ctx.strength_sell;
   double opposite_acceptance = direction>0 ? ctx.acceptance_sell : ctx.acceptance_buy;
   double clean      = MarketCleanContextScore(ctx,direction);
   double gap        = opposite_acceptance - acceptance;

   // Oro: activo líder verificado. Se le permite respirar, pero no entrar en trampa de rechazo.
   if(IsGoldSymbol(ctx.symbol))
   {
      if(wick>0.68 && follow<0.50)
      {
         reason="ASSET_ROLE_GOLD_REJECTION_TRAP";
         return false;
      }
      reason="ASSET_ROLE_GOLD_ALLOW";
      return true;
   }

   // V4.6: motores particulares por activo.
   // No se usa una exigencia genérica de índice porque eso sesga el EA hacia Oro.
   if(EnableAssetSpecificEngine)
   {
      if(StartsWith(ctx.symbol,"US500"))
      {
         // SP500: continuidad limpia y alineación. No exigir explosión extrema.
         if(follow < US500_MinFollow)
         {
            reason="ASSET_SPECIFIC_US500_FOLLOW_WEAK";
            return false;
         }
         if(acceptance < US500_MinAcceptance)
         {
            reason="ASSET_SPECIFIC_US500_ACCEPTANCE_WEAK";
            return false;
         }
         if(clean < US500_MinCleanContext)
         {
            reason="ASSET_SPECIFIC_US500_CONTEXT_DIRTY";
            return false;
         }
         if(wick > US500_MaxWickRisk)
         {
            reason="ASSET_SPECIFIC_US500_WICK_RISK";
            return false;
         }
         if(gap > US500_MaxOppAcceptanceGap || align < US500_MinAlignment)
         {
            reason="ASSET_SPECIFIC_US500_DIRECTION_CONFLICT";
            return false;
         }
         reason="ASSET_SPECIFIC_US500_ALLOW";
         return true;
      }

      if(StartsWith(ctx.symbol,"US100"))
      {
         // NASDAQ: necesita momentum real. Puede tolerar más ruido que SP500,
         // pero no puede entrar sin fuerza.
         if(follow < US100_MinFollow)
         {
            reason="ASSET_SPECIFIC_US100_FOLLOW_WEAK";
            return false;
         }
         if(acceptance < US100_MinAcceptance)
         {
            reason="ASSET_SPECIFIC_US100_ACCEPTANCE_WEAK";
            return false;
         }
         if(clean < US100_MinCleanContext)
         {
            reason="ASSET_SPECIFIC_US100_CONTEXT_DIRTY";
            return false;
         }
         if(wick > US100_MaxWickRisk)
         {
            reason="ASSET_SPECIFIC_US100_WICK_RISK";
            return false;
         }
         if(strength < US100_MinStrength)
         {
            reason="ASSET_SPECIFIC_US100_STRENGTH_WEAK";
            return false;
         }
         reason="ASSET_SPECIFIC_US100_ALLOW";
         return true;
      }

      if(StartsWith(ctx.symbol,"GER40"))
      {
         // DAX: sensible a fake breaks y apertura europea. Exige sesión viva,
         // follow-through y mecha controlada.
         if(follow < GER40_MinFollow)
         {
            reason="ASSET_SPECIFIC_GER40_FOLLOW_WEAK";
            return false;
         }
         if(acceptance < GER40_MinAcceptance)
         {
            reason="ASSET_SPECIFIC_GER40_ACCEPTANCE_WEAK";
            return false;
         }
         if(clean < GER40_MinCleanContext)
         {
            reason="ASSET_SPECIFIC_GER40_CONTEXT_DIRTY";
            return false;
         }
         if(wick > GER40_MaxWickRisk)
         {
            reason="ASSET_SPECIFIC_GER40_WICK_RISK";
            return false;
         }
         if(ctx.session_activity_score < GER40_MinSessionActivity)
         {
            reason="ASSET_SPECIFIC_GER40_SESSION_WEAK";
            return false;
         }
         reason="ASSET_SPECIFIC_GER40_ALLOW";
         return true;
      }
   }

   // Legacy V4.5: índices con regla A+ común.
   if(IsIndexSymbol(ctx.symbol))
   {
      if(survival_score < IndexAPlusMinSurvival)
      {
         reason="ASSET_ROLE_INDEX_NOT_A_PLUS";
         return false;
      }
      if(follow < IndexAPlusMinFollow)
      {
         reason="ASSET_ROLE_INDEX_FOLLOW_WEAK";
         return false;
      }
      if(acceptance < IndexAPlusMinAcceptance)
      {
         reason="ASSET_ROLE_INDEX_ACCEPTANCE_WEAK";
         return false;
      }
      if(clean < IndexAPlusMinCleanContext)
      {
         reason="ASSET_ROLE_INDEX_CONTEXT_DIRTY";
         return false;
      }
      if(wick > IndexAPlusMaxWickRisk)
      {
         reason="ASSET_ROLE_INDEX_WICK_RISK";
         return false;
      }
      if(gap > IndexAPlusMaxOppAcceptanceGap || align < 0.68)
      {
         reason="ASSET_ROLE_INDEX_DIRECTION_CONFLICT";
         return false;
      }
      if(US500OnlyAPlus && StartsWith(ctx.symbol,"US500") && (survival_score < IndexAPlusMinSurvival+4.0 || follow < IndexAPlusMinFollow+0.04))
      {
         reason="ASSET_ROLE_US500_ONLY_A_PLUS";
         return false;
      }
   }

   reason="ASSET_ROLE_ALLOW";
   return true;
}

bool TradeSurvivalPasses(MarketContext &ctx,int direction,int idx,string &reason,double &survival_score,double &required_score,double &death_risk)
{
   survival_score = 100.0;
   required_score = 0.0;
   death_risk     = 0.0;

   if(!EnableTradeSurvivalEngine)
   {
      reason="TRADE_SURVIVAL_DISABLED";
      return true;
   }

   survival_score = TradeSurvivalScore(ctx,direction,idx);
   required_score = RequiredTradeSurvivalScore(ctx.symbol,idx);
   death_risk     = ImmediateDeathRiskScore(ctx,direction);
   double max_death = AllowedImmediateDeathRisk(ctx.symbol);

   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double opposite_acceptance = direction>0 ? ctx.acceptance_sell : ctx.acceptance_buy;

   string asset_role_reason="";
   if(!AssetRolePasses(ctx,direction,asset_role_reason,survival_score))
   {
      reason=asset_role_reason;
      return false;
   }

   if(death_risk > max_death)
   {
      reason="TSI_IMMEDIATE_DEATH_RISK";
      return false;
   }

   // Bloqueo quirúrgico: solo casos de muerte temprana muy probable.
   if(wick>=0.66 && rejection>=0.58 && follow<0.50)
   {
      reason="TSI_REJECTION_WICK_FOLLOW_FAIL";
      return false;
   }

   if(opposite_acceptance > acceptance + 0.16 && align<0.58)
   {
      reason="TSI_OPPOSITE_ACCEPTANCE_DOMINATES";
      return false;
   }

   if(IsIndexSymbol(ctx.symbol) && follow<IndexFollowSoftFloor && acceptance<0.68)
   {
      reason="TSI_INDEX_NO_FOLLOW_THROUGH";
      return false;
   }

   if(survival_score < required_score)
   {
      reason="TSI_SURVIVAL_SCORE_LOW";
      return false;
   }

   reason="TSI_SURVIVAL_ALLOW";
   return true;
}

double ContextLotBoost(MarketContext &ctx, int direction)
{
   if(!UseContextLotBoost)
      return 1.0;

   if(DisableContextBoostInDefense && (ProfitDefenseSoftActive() || ProfitDefenseHardActive() || CurrentProfitProtectionState()!=CPP_STATE_NORMAL))
      return 1.0;

   double transition = AdaptiveTransitionScore(ctx, direction);
   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;

   if(transition < MinContextScoreForBoost)
      return 1.0;

   double quality = 0.0;
   quality += Clamp01((transition - MinContextScoreForBoost) / 18.0) * 0.45;
   quality += Clamp01((expansion - 0.62) / 0.25) * 0.25;
   quality += Clamp01((acceptance - 0.58) / 0.25) * 0.20;
   quality += Clamp01((0.45 - wick) / 0.25) * 0.10;

   double boost = 1.0 + quality * (MaxContextLotBoost - 1.0);

   if(boost < 1.0) boost = 1.0;
   if(boost > MaxContextLotBoost) boost = MaxContextLotBoost;

   return boost;
}



double BrokerWorstLossMoney(string symbol,int direction,double lots,double open_price,double sl)
{
   if(lots<=0.0 || open_price<=0.0 || sl<=0.0)
      return 0.0;

   ENUM_ORDER_TYPE order_type = direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double profit_at_sl = 0.0;
   if(!OrderCalcProfit(order_type,symbol,lots,open_price,sl,profit_at_sl))
      return 0.0;

   if(profit_at_sl >= 0.0)
      return 0.0;

   return MathAbs(profit_at_sl);
}

double EnforceBrokerHardRiskLot(string symbol,int direction,double lots,double open_price,double sl)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double max_loss = equity * HardMaxLossPerTradePercent / 100.0;

   double step = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   if(step<=0.0) step=0.01;
   if(vmin<=0.0) vmin=MinLot;

   lots = NormalizeVolume(symbol,lots);

   double loss = BrokerWorstLossMoney(symbol,direction,lots,open_price,sl);
   if(loss>0.0 && loss<=max_loss)
      return lots;

   while(lots>=vmin)
   {
      lots -= step;
      lots = MathFloor(lots/step)*step;
      lots = NormalizeVolume(symbol,lots);

      if(lots<vmin)
         break;

      loss = BrokerWorstLossMoney(symbol,direction,lots,open_price,sl);
      if(loss>0.0 && loss<=max_loss)
         return lots;
   }

   return 0.0;
}



// ==================================================================
// V5.3 — INTERNAL ASSET ENGINES + GLOBAL OPPORTUNITY RANKING
// ==================================================================
double DirectionMetric(MarketContext &ctx,int direction,string metric)
{
   if(metric=="expansion") return direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   if(metric=="acceptance") return direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   if(metric=="follow") return direction>0 ? ctx.follow_buy : ctx.follow_sell;
   if(metric=="wick") return direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   if(metric=="rejection") return direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   if(metric=="align") return direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   if(metric=="strength") return direction>0 ? ctx.strength_buy : ctx.strength_sell;
   if(metric=="room") return direction>0 ? ctx.volatility_room_buy : ctx.volatility_room_sell;
   if(metric=="score") return direction>0 ? ctx.score_buy : ctx.score_sell;
   return 0.0;
}


bool V54_IsGoldBuyBadHour(int hour)
{
   return (hour==9 || hour==12 || hour==13 || hour==15);
}

bool V54_IsUS500BuyBadHour(int hour)
{
   return (hour==13);
}

bool V510_GoldBuyCatastropheRejects(MarketContext &ctx,int direction)
{
   if(!EnableV510GoldBuyCatastropheShield)
      return false;
   if(!IsGoldSymbol(ctx.symbol) || direction<=0)
      return false;

   double wick=DirectionMetric(ctx,direction,"wick");
   double rejection=DirectionMetric(ctx,direction,"rejection");
   double acceptance=DirectionMetric(ctx,direction,"acceptance");
   double follow=DirectionMetric(ctx,direction,"follow");

   // Blindaje extremadamente conservador:
   // solo bloquea BUY cuando hay rechazo superior + falta de aceptación + falta de continuidad.
   // No intenta optimizar; evita la peor familia estructural.
   if(wick>=V510_GoldBuyMaxWickCatastrophe &&
      rejection>=V510_GoldBuyMaxRejectionCatastrophe &&
      acceptance<=V510_GoldBuyMinAcceptanceCatastrophe &&
      follow<=V510_GoldBuyMinFollowCatastrophe &&
      ctx.range_efficiency<=V510_GoldBuyMaxRangeEffCatastrophe)
      return true;

   return false;
}

double RequiredRankingScore(string symbol)
{
   if(IsGoldSymbol(symbol)) return Ranking_MinScoreGold;
   if(StartsWith(symbol,"US500")) return Ranking_MinScoreUS500;
   if(StartsWith(symbol,"US100")) return Ranking_MinScoreUS100;
   if(StartsWith(symbol,"GER40")) return Ranking_MinScoreGER40;
   return 68.0;
}

double GoldInternalEngineScore(MarketContext &ctx,int direction,int idx)
{
   double expansion=DirectionMetric(ctx,direction,"expansion");
   double acceptance=DirectionMetric(ctx,direction,"acceptance");
   double follow=DirectionMetric(ctx,direction,"follow");
   double wick=DirectionMetric(ctx,direction,"wick");
   double rejection=DirectionMetric(ctx,direction,"rejection");
   double align=DirectionMetric(ctx,direction,"align");
   double strength=DirectionMetric(ctx,direction,"strength");
   double life=ExpansionLifecycleScore(ctx,direction);
   double decay=ExpansionDecayScore(ctx,direction);
   double selector=SelectorQualityScore(ctx,direction);

   double score=0.0;
   score += selector*0.22;
   score += life*0.18;
   score += expansion*11.0;
   score += acceptance*13.0;
   score += follow*10.0;
   score += align*8.0;
   score += strength*7.0;
   score += (1.0-wick)*8.0;
   score += (1.0-rejection)*5.0;
   score += ctx.liquidity_quality*4.0;
   score -= decay*0.06;

   // Oro BUY y Oro SELL no son la misma conducta. SELL recibe permiso si la continuidad es clara.
   if(direction<0 && follow>=0.52 && acceptance>=0.60 && wick<=0.56)
      score += Ranking_GoldContinuityBonus;
   if(direction>0 && ctx.range_efficiency<0.10 && follow<0.58)
      score -= 5.0;

   // V5.4: no matar el oro. Solo penalizar BUY en horas que V5.3 mostró negativas,
   // salvo cuando el propio motor interno detecta oportunidad excepcional.
   if(EnableV54SurgicalRankingRefinement)
   {
      if(direction>0 && V54_IsGoldBuyBadHour(ctx.hour_server))
      {
         double exceptional = selector*0.35 + life*0.25 + acceptance*15.0 + follow*15.0 + align*10.0;
         if(exceptional < V54_GoldBuyBadHourExceptionalScore)
            score -= V54_GoldBuyBadHourPenalty;
      }

      // V5.3 demostró fuerza clara en XAUUSD SELL; se preserva si hay continuidad limpia.
      if(direction<0 && follow>=0.54 && acceptance>=0.60 && wick<=0.58)
         score += V54_GoldSellPreserveBonus;
   }

   if(idx>=0 && idx<ArraySize(g_states))
      score -= g_states[idx].consecutive_losses*Ranking_RecentLossPenalty;

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

double US500InternalEngineScore(MarketContext &ctx,int direction,int idx)
{
   double acceptance=DirectionMetric(ctx,direction,"acceptance");
   double follow=DirectionMetric(ctx,direction,"follow");
   double wick=DirectionMetric(ctx,direction,"wick");
   double align=DirectionMetric(ctx,direction,"align");
   double strength=DirectionMetric(ctx,direction,"strength");
   double clean=MarketCleanContextScore(ctx,direction);
   double fresh=ImpulseFreshnessScore(ctx,direction);
   double death=ImmediateDeathRiskScore(ctx,direction);
   double conflict=DirectionConflictScore(ctx,direction);

   double score=0.0;
   score += clean*0.24;
   score += fresh*0.12;
   score += acceptance*15.0;
   score += follow*16.0;
   score += align*13.0;
   score += ctx.range_efficiency*10.0;
   score += (1.0-wick)*10.0;
   score += strength*5.0;
   score += ctx.session_activity_score*4.0;
   score -= death*0.10;
   score -= conflict*5.0;

   if(follow>=US500_MinFollow && acceptance>=US500_MinAcceptance && ctx.range_efficiency>=US500_MinRangeEfficiency && wick<=US500_MaxWickRisk)
      score += Ranking_USIndexCleanBonus;
   if(direction<0 && follow<0.58)
      score -= 4.0;
   if(ctx.hour_server==13 && direction>0 && ctx.range_efficiency<0.32)
      score -= 3.0;

   // V5.4: US500 BUY a las 13:00 fue el hueco más claro; US500 SELL sigue sin justificar riesgo.
   if(EnableV54SurgicalRankingRefinement)
   {
      if(direction>0 && V54_IsUS500BuyBadHour(ctx.hour_server))
         score -= V54_US500BuyHour13Penalty;
      if(direction<0)
         score -= V54_US500SellPenalty;
   }

   if(idx>=0 && idx<ArraySize(g_states))
      score -= g_states[idx].consecutive_losses*Ranking_RecentLossPenalty;

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

double US100InternalEngineScore(MarketContext &ctx,int direction,int idx)
{
   double expansion=DirectionMetric(ctx,direction,"expansion");
   double acceptance=DirectionMetric(ctx,direction,"acceptance");
   double follow=DirectionMetric(ctx,direction,"follow");
   double wick=DirectionMetric(ctx,direction,"wick");
   double align=DirectionMetric(ctx,direction,"align");
   double strength=DirectionMetric(ctx,direction,"strength");
   double fresh=ImpulseFreshnessScore(ctx,direction);
   double death=ImmediateDeathRiskScore(ctx,direction);

   double score=0.0;
   score += fresh*0.20;
   score += expansion*18.0;
   score += strength*17.0;
   score += follow*13.0;
   score += acceptance*12.0;
   score += align*10.0;
   score += (1.0-wick)*8.0;
   score += ctx.range_efficiency*5.0;
   score -= death*0.08;

   if(expansion>=US100_MinMomentumExpansion && strength>=US100_MinStrength && follow>=US100_MinFollow)
      score += 3.0;

   if(idx>=0 && idx<ArraySize(g_states))
      score -= g_states[idx].consecutive_losses*Ranking_RecentLossPenalty;

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

double GER40InternalEngineScore(MarketContext &ctx,int direction,int idx)
{
   double acceptance=DirectionMetric(ctx,direction,"acceptance");
   double follow=DirectionMetric(ctx,direction,"follow");
   double wick=DirectionMetric(ctx,direction,"wick");
   double align=DirectionMetric(ctx,direction,"align");
   double strength=DirectionMetric(ctx,direction,"strength");
   double conflict=DirectionConflictScore(ctx,direction);

   double score=0.0;
   score += strength*20.0;
   score += follow*18.0;
   score += acceptance*14.0;
   score += align*14.0;
   score += (1.0-wick)*14.0;
   score += ctx.session_activity_score*10.0;
   score += (1.0-conflict)*6.0;
   score += ctx.range_efficiency*4.0;

   if(ctx.hour_server<GER40_TimingStartHour || ctx.hour_server>=GER40_TimingEndHour)
      score -= 20.0;
   if(wick>GER40_MaxWickRisk || conflict>GER40_MaxTimingConflict)
      score -= 8.0;

   // V5.4: GER40 queda como observador competitivo. Solo debe ganar si la oportunidad es extraordinaria.
   if(EnableV54SurgicalRankingRefinement)
      score -= V54_GER40ObserverPenalty;

   if(idx>=0 && idx<ArraySize(g_states))
      score -= g_states[idx].consecutive_losses*Ranking_RecentLossPenalty;

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

double AssetInternalOpportunityScore(MarketContext &ctx,int direction,int idx)
{
   if(IsGoldSymbol(ctx.symbol)) return GoldInternalEngineScore(ctx,direction,idx);
   if(StartsWith(ctx.symbol,"US500")) return US500InternalEngineScore(ctx,direction,idx);
   if(StartsWith(ctx.symbol,"US100")) return US100InternalEngineScore(ctx,direction,idx);
   if(StartsWith(ctx.symbol,"GER40")) return GER40InternalEngineScore(ctx,direction,idx);

   double score=SelectorQualityScore(ctx,direction)*0.40 + MarketCleanContextScore(ctx,direction)*0.30 + ImpulseFreshnessScore(ctx,direction)*0.20 + ExpansionLifecycleScore(ctx,direction)*0.10;
   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

void ResetCandidates()
{
   g_candidate_count=0;
   ArrayResize(g_candidates,0);
}

void RegisterAssetCandidate(int idx,MarketContext &ctx,int direction,string reason)
{
   if(!EnableGlobalOpportunityRanking)
   {
      ExecuteEntry(idx,ctx,direction,reason);
      return;
   }

   if(V510_GoldBuyCatastropheRejects(ctx,direction))
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED","V510_GOLD_BUY_CATASTROPHE_REJECTION",0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,AdaptiveTransitionScore(ctx,direction),"",0.0,0.0,0.0,0.0,0.0);
      return;
   }

   double score=AssetInternalOpportunityScore(ctx,direction,idx);
   double required=RequiredRankingScore(ctx.symbol);

   if(EnableV54SurgicalRankingRefinement && V54_BlockGER40UnlessExceptional && StartsWith(ctx.symbol,"GER40") && score < V54_GER40ExceptionalScore)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED","V54_GER40_OBSERVER_MODE",0,0.0,0.0,0.0,0.0,0.0,0.0,V54_GER40ExceptionalScore,score,"",0.0,0.0,0.0,0.0,0.0);
      return;
   }

   if(score < required)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED","GLOBAL_RANKING_SCORE_LOW",0,0.0,0.0,0.0,0.0,0.0,0.0,required,score,"",0.0,0.0,0.0,0.0,0.0);
      return;
   }

   int n=ArraySize(g_candidates);
   if(n>=MaxCandidatesPerCycle)
      return;

   ArrayResize(g_candidates,n+1);
   g_candidates[n].active=true;
   g_candidates[n].idx=idx;
   g_candidates[n].ctx=ctx;
   g_candidates[n].direction=direction;
   g_candidates[n].score=score;
   g_candidates[n].reason=reason+"_ASSET_ENGINE_SCORE_"+DoubleToString(score,2);
   g_candidate_count=n+1;

   Audit(ctx,g_states[idx],direction,"DECISION","CANDIDATE","GLOBAL_RANKING_CANDIDATE",0,0.0,0.0,0.0,0.0,0.0,0.0,required,score,"",0.0,0.0,0.0,0.0,0.0,0.0,0.0,"",0.0,0.0,"",0.0,0.0,0.0,0.0,0.0,"",
         (EnableV524RankingBiasSimulator ? "V524_CANDIDATE_SIM_SCORE" : ""),score,V524RegimeBiasScore(ctx,direction),V524SimulatedFinalScore(ctx,direction,score),"","","");
}

void ExecuteBestCandidate()
{
   if(!EnableGlobalOpportunityRanking || g_candidate_count<=0)
      return;

   int best=-1;
   double best_score=-1.0;
   for(int i=0;i<g_candidate_count;i++)
   {
      if(!g_candidates[i].active) continue;
      if(g_candidates[i].score>best_score)
      {
         best_score=g_candidates[i].score;
         best=i;
      }
   }

   if(best<0)
      return;

   // V5.24: simulated ranking audit.
   // This does NOT change the actual winner. It only records what a regime-aware
   // ranking would have preferred if it were active.
   if(EnableV524RankingBiasSimulator && V524_AuditSimulatedRanking)
   {
      int sim_best=-1;
      double sim_best_score=-DBL_MAX;
      for(int j=0;j<g_candidate_count;j++)
      {
         if(!g_candidates[j].active) continue;
         double sim_score = V524SimulatedFinalScore(g_candidates[j].ctx,g_candidates[j].direction,g_candidates[j].score);
         if(sim_score > sim_best_score)
         {
            sim_best_score=sim_score;
            sim_best=j;
         }
      }

      string actual_asset = g_candidates[best].ctx.symbol + "_" + DirToString(g_candidates[best].direction);
      string sim_asset = (sim_best>=0 ? g_candidates[sim_best].ctx.symbol + "_" + DirToString(g_candidates[sim_best].direction) : "NONE");
      string changed = (sim_best>=0 && sim_best!=best ? "YES" : "NO");

      for(int j=0;j<g_candidate_count;j++)
      {
         if(!g_candidates[j].active) continue;
         double bias = V524RegimeBiasScore(g_candidates[j].ctx,g_candidates[j].direction);
         double sim_score = g_candidates[j].score + bias;
         string sim_reason = (j==sim_best ? "V524_SIMULATED_RANKING_PREFERRED" : "V524_SIMULATED_RANKING_NOT_PREFERRED");
         Audit(g_candidates[j].ctx,g_states[g_candidates[j].idx],g_candidates[j].direction,"DECISION","OBSERVE",sim_reason,0,0.0,0.0,0.0,0.0,0.0,0.0,best_score,g_candidates[j].score,"",0.0,0.0,0.0,0.0,0.0,0.0,0.0,"",0.0,0.0,"",0.0,0.0,0.0,0.0,0.0,"","V524_SIMULATED_RANKING",g_candidates[j].score,bias,sim_score,actual_asset,sim_asset,changed);
      }
   }

   for(int i=0;i<g_candidate_count;i++)
   {
      if(!g_candidates[i].active) continue;
      if(i==best) continue;

      if(Ranking_AuditLosingCandidates)
         Audit(g_candidates[i].ctx,g_states[g_candidates[i].idx],g_candidates[i].direction,"DECISION","BLOCKED","LOST_GLOBAL_OPPORTUNITY_COMPETITION",0,0.0,0.0,0.0,0.0,0.0,0.0,best_score,g_candidates[i].score,"",0.0,0.0,0.0,0.0,0.0);

      // La señal no elegida no queda pendiente; debe volver a competir en la siguiente barra.
      g_states[g_candidates[i].idx].state=TS_NORMAL;
      g_states[g_candidates[i].idx].state_direction=0;
      g_states[g_candidates[i].idx].state_age_bars=0;
   }

   ExecuteEntry(g_candidates[best].idx,g_candidates[best].ctx,g_candidates[best].direction,g_candidates[best].reason);
}


// ==================================================================
// V5.18 — LEARNING ENGINE MEMORY
// ==================================================================
int V518FindMemoryByTicket(ulong ticket)
{
   for(int i=0;i<ArraySize(g_v518_trades);i++)
      if(g_v518_trades[i].active && g_v518_trades[i].ticket==ticket) return i;
   return -1;
}

int V518FindMemoryBySymbol(string symbol)
{
   for(int i=0;i<ArraySize(g_v518_trades);i++)
      if(g_v518_trades[i].active && g_v518_trades[i].symbol==symbol) return i;
   return -1;
}

string V518ResultClass(double r_multiple, double pnl)
{
   if(r_multiple>=V518_BigWinR) return "BIG_WIN";
   if(r_multiple>=V518_SmallWinR) return "SMALL_WIN";
   if(r_multiple>0.0 || pnl>0.0) return "TINY_WIN";
   if(r_multiple<=V518_BigLossR) return "BIG_LOSS";
   if(r_multiple<0.0 || pnl<0.0) return "SMALL_LOSS";
   return "FLAT";
}

void V518RegisterTrade(ulong ticket, MarketContext &ctx, int direction, double volume, double price, double sl, double tp, double reader_score, double required_score, string reader_reason)
{
   if(!EnableV518LearningEngine) return;
   if(ticket==0) return;

   int pos=V518FindMemoryByTicket(ticket);
   if(pos<0)
   {
      pos=ArraySize(g_v518_trades);
      ArrayResize(g_v518_trades,pos+1);
   }

   g_v518_trades[pos].active=true;
   g_v518_trades[pos].ticket=ticket;
   g_v518_trades[pos].symbol=ctx.symbol;
   g_v518_trades[pos].direction=direction;
   g_v518_trades[pos].open_time=TimeCurrent();
   g_v518_trades[pos].entry_price=price;
   g_v518_trades[pos].sl=sl;
   g_v518_trades[pos].tp=tp;
   g_v518_trades[pos].volume=volume;
   g_v518_trades[pos].entry_reader_score=reader_score;
   g_v518_trades[pos].entry_required_score=required_score;
   g_v518_trades[pos].entry_conflict=DirectionConflictScore(ctx,direction);
   g_v518_trades[pos].entry_false_expansion=FalseExpansionRisk(ctx,direction);
   g_v518_trades[pos].entry_immediate_death=ImmediateDeathRiskScore(ctx,direction);
   g_v518_trades[pos].mfe_r=0.0;
   g_v518_trades[pos].mae_r=0.0;
   g_v518_trades[pos].entry_reader_reason=reader_reason;
   g_v518_trades[pos].v519_lifecycle_protected=false;
   g_v518_trades[pos].v520_hit_05r=false;
   g_v518_trades[pos].v520_hit_1r=false;
   g_v518_trades[pos].v520_hit_2r=false;
   g_v518_trades[pos].v520_hit_3r=false;
   g_v518_trades[pos].v520_max_pullback_after_1r=0.0;
}

void V518UpdateOpenTrade(ulong ticket, string symbol, int direction, double r_now)
{
   if(!EnableV518LearningEngine || !V518_TrackMFE_MAE) return;

   int pos=V518FindMemoryByTicket(ticket);
   if(pos<0) pos=V518FindMemoryBySymbol(symbol);
   if(pos<0) return;

   if(r_now>g_v518_trades[pos].mfe_r) g_v518_trades[pos].mfe_r=r_now;
   if(r_now<g_v518_trades[pos].mae_r) g_v518_trades[pos].mae_r=r_now;
}

// V5.20 — Lifecycle Observer Advanced. Observa hit-levels y pullback después de +1R.
void V520ObserveLifecycle(ulong ticket, string symbol, int direction, double volume, double pnl, double r_now, MarketContext &ctx, SymbolState &st, string phase, double life_score, double decay_score)
{
   if(!EnableV520LifecycleObserver)
      return;

   int pos=V518FindMemoryByTicket(ticket);
   if(pos<0) pos=V518FindMemoryBySymbol(symbol);
   if(pos<0) return;

   if(g_v518_trades[pos].v520_hit_1r)
   {
      double pullback = g_v518_trades[pos].mfe_r - r_now;
      if(pullback > g_v518_trades[pos].v520_max_pullback_after_1r)
         g_v518_trades[pos].v520_max_pullback_after_1r = pullback;
   }

   if(r_now >= V520_Level05R && !g_v518_trades[pos].v520_hit_05r)
   {
      g_v518_trades[pos].v520_hit_05r = true;
      if(V520_AuditHitLevels)
         Audit(ctx,st,direction,"MANAGE","LIFECYCLE_OBSERVE","V520_HIT_0_5R",ticket,volume,0.0,0.0,0.0,pnl,r_now,0.0,0.0,phase,life_score,decay_score,0.0,0.0);
   }

   if(r_now >= V520_Level1R && !g_v518_trades[pos].v520_hit_1r)
   {
      g_v518_trades[pos].v520_hit_1r = true;
      if(V520_AuditHitLevels)
         Audit(ctx,st,direction,"MANAGE","LIFECYCLE_OBSERVE","V520_HIT_1R",ticket,volume,0.0,0.0,0.0,pnl,r_now,0.0,0.0,phase,life_score,decay_score,0.0,0.0);
   }

   if(r_now >= V520_Level2R && !g_v518_trades[pos].v520_hit_2r)
   {
      g_v518_trades[pos].v520_hit_2r = true;
      if(V520_AuditHitLevels)
         Audit(ctx,st,direction,"MANAGE","LIFECYCLE_OBSERVE","V520_HIT_2R",ticket,volume,0.0,0.0,0.0,pnl,r_now,0.0,0.0,phase,life_score,decay_score,0.0,0.0);
   }

   if(r_now >= V520_Level3R && !g_v518_trades[pos].v520_hit_3r)
   {
      g_v518_trades[pos].v520_hit_3r = true;
      if(V520_AuditHitLevels)
         Audit(ctx,st,direction,"MANAGE","LIFECYCLE_OBSERVE","V520_HIT_3R",ticket,volume,0.0,0.0,0.0,pnl,r_now,0.0,0.0,phase,life_score,decay_score,0.0,0.0);
   }
}

bool V518GetAndDeactivate(string symbol, ulong ticket, V518TradeMemory &mem)
{
   int pos=V518FindMemoryByTicket(ticket);
   if(pos<0) pos=V518FindMemoryBySymbol(symbol);
   if(pos<0) return false;

   mem=g_v518_trades[pos];
   g_v518_trades[pos].active=false;
   return true;
}

// ==================================================================
// V5.16 — MARKET READER GATEKEEPER
// ==================================================================
double V516RequiredGatekeeperScore(string symbol)
{
   if(IsGoldSymbol(symbol)) return V516_MinScoreGold;
   if(StartsWith(symbol,"US500")) return V516_MinScoreUS500;
   if(StartsWith(symbol,"US100")) return V516_MinScoreUS100;
   if(StartsWith(symbol,"GER40")) return V516_MinScoreGER40;
   return V516_MinScoreDefault;
}

double V516AllowedConflict(string symbol)
{
   if(IsGoldSymbol(symbol)) return V516_MaxConflictGold;
   if(StartsWith(symbol,"US500")) return V516_MaxConflictUS500;
   if(StartsWith(symbol,"US100")) return V516_MaxConflictUS100;
   if(StartsWith(symbol,"GER40")) return V516_MaxConflictGER40;
   return 0.38;
}

double V516AllowedFalseExpansion(string symbol)
{
   if(IsGoldSymbol(symbol)) return V516_MaxFalseExpansionGold;
   if(StartsWith(symbol,"US500")) return V516_MaxFalseExpansionUS500;
   if(StartsWith(symbol,"US100")) return V516_MaxFalseExpansionUS100;
   if(StartsWith(symbol,"GER40")) return V516_MaxFalseExpansionGER40;
   return 48.0;
}

double V516AllowedImmediateDeath(string symbol)
{
   if(IsGoldSymbol(symbol)) return V516_MaxImmediateDeathGold;
   if(StartsWith(symbol,"US500")) return V516_MaxImmediateDeathUS500;
   if(StartsWith(symbol,"US100")) return V516_MaxImmediateDeathUS100;
   if(StartsWith(symbol,"GER40")) return V516_MaxImmediateDeathGER40;
   return 66.0;
}

double V516MarketReaderScore(MarketContext &ctx,int direction,int idx)
{
   double regime    = AssetRegimeReadScore(ctx,direction);
   double selector  = SelectorQualityScore(ctx,direction);
   double survival  = TradeSurvivalScore(ctx,direction,idx);
   double clean     = MarketCleanContextScore(ctx,direction);
   double fresh     = ImpulseFreshnessScore(ctx,direction);
   double life      = ExpansionLifecycleScore(ctx,direction);
   double false_exp = FalseExpansionRisk(ctx,direction);
   double death     = ImmediateDeathRiskScore(ctx,direction);
   double conflict  = DirectionConflictScore(ctx,direction) * 100.0;
   double decay     = ExpansionDecayScore(ctx,direction);

   double score = 0.0;
   score += regime   * 0.26;
   score += selector * 0.20;
   score += survival * 0.16;
   score += clean    * 0.14;
   score += fresh    * 0.10;
   score += life     * 0.06;
   score += (ctx.spread_quality    * 100.0) * 0.04;
   score += (ctx.liquidity_quality * 100.0) * 0.04;

   score -= false_exp * 0.06;
   score -= death     * 0.05;
   score -= conflict  * 0.04;
   score -= decay     * 0.03;

   // Sesgo quirúrgico por activo: no cambia la señal, solo interpreta su idioma.
   if(IsGoldSymbol(ctx.symbol))
   {
      double follow = direction>0 ? ctx.follow_buy : ctx.follow_sell;
      double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
      double wick = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
      if(follow>=0.52 && acceptance>=0.58 && wick<=0.58)
         score += 2.0;
   }
   else if(StartsWith(ctx.symbol,"US500"))
   {
      double follow = direction>0 ? ctx.follow_buy : ctx.follow_sell;
      double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
      double align = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
      if(follow>=0.46 && acceptance>=0.56 && align>=0.56)
         score += 2.0;
   }
   else if(StartsWith(ctx.symbol,"US100"))
   {
      double strength = direction>0 ? ctx.strength_buy : ctx.strength_sell;
      double expansion = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
      if(strength>=0.60 && expansion>=0.62)
         score += 1.5;
   }
   else if(StartsWith(ctx.symbol,"GER40"))
   {
      // GER40 permanece en modo observador competitivo: solo pasa lectura excepcional.
      if(ctx.hour_server < GER40_TimingStartHour || ctx.hour_server >= GER40_TimingEndHour)
         score -= 8.0;
   }

   if(idx>=0 && idx<ArraySize(g_states))
      score -= (double)g_states[idx].consecutive_losses * 1.5;

   if(score<0.0) score=0.0;
   if(score>100.0) score=100.0;
   return score;
}

bool V516MarketReaderGatekeeperPasses(MarketContext &ctx,int direction,int idx,string &reason,double &score,double &required)
{
   // V5.17: OBSERVER MODE.
   // Esta función conserva el nombre legado de V5.16 para no tocar la arquitectura,
   // pero ya NO bloquea. Calcula qué habría hecho el Gatekeeper y lo audita.
   // La operación madre sigue pasando a las capas originales del sistema.
   score = 100.0;
   required = 0.0;

   if(!EnableV516MarketReaderGatekeeper)
   {
      reason="V517_MARKET_READER_OBSERVER_DISABLED";
      return true;
   }

   required = V516RequiredGatekeeperScore(ctx.symbol);
   score = V516MarketReaderScore(ctx,direction,idx);

   double conflict  = DirectionConflictScore(ctx,direction);
   double false_exp = FalseExpansionRisk(ctx,direction);
   double death     = ImmediateDeathRiskScore(ctx,direction);
   double regime    = AssetRegimeReadScore(ctx,direction);

   string would_block="";

   if(ctx.spread_quality < V516_MinSpreadQuality)
      would_block="V517_OBSERVE_WOULD_BLOCK_SPREAD_QUALITY_LOW";
   else if(ctx.liquidity_quality < V516_MinLiquidityQuality)
      would_block="V517_OBSERVE_WOULD_BLOCK_LIQUIDITY_QUALITY_LOW";
   else if(conflict > V516AllowedConflict(ctx.symbol))
      would_block="V517_OBSERVE_WOULD_BLOCK_DIRECTION_CONFLICT";
   else if(false_exp > V516AllowedFalseExpansion(ctx.symbol))
      would_block="V517_OBSERVE_WOULD_BLOCK_FALSE_EXPANSION";
   else if(death > V516AllowedImmediateDeath(ctx.symbol))
      would_block="V517_OBSERVE_WOULD_BLOCK_IMMEDIATE_DEATH_RISK";
   else if(regime < RequiredAssetRegimeScore(ctx.symbol) - 3.0)
      would_block="V517_OBSERVE_WOULD_BLOCK_REGIME_NOT_CLEAR";
   else if(score < required)
      would_block="V517_OBSERVE_WOULD_BLOCK_SCORE_LOW";

   if(would_block != "")
      reason = would_block;
   else
      reason = "V517_OBSERVE_MARKET_READER_OK";

   return true;
}

void ExecuteEntry(int idx,MarketContext &ctx,int direction,string entry_reason)
{
   double selector_quality=SelectorQualityScore(ctx,direction);
   double selector_required=RequiredSelectorQuality(ctx.symbol);
   selector_required += ProfitDefenseQualityAdd();

   if(selector_quality < selector_required)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED","SELECTOR_QUALITY_LOW",0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,AdaptiveTransitionScore(ctx,direction),"",0.0,0.0,0.0,0.0,0.0);
      return;
   }

   if(EnableAdaptiveCooldown && g_states[idx].cooldown_until>0 && TimeCurrent()<g_states[idx].cooldown_until)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED","ASSET_COOLDOWN_ACTIVE",0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,AdaptiveTransitionScore(ctx,direction),"",0.0,0.0,0.0,0.0,0.0);
      return;
   }

   string v516_reason="";
   double v516_score=0.0;
   double v516_required=0.0;
   if(!V516MarketReaderGatekeeperPasses(ctx,direction,idx,v516_reason,v516_score,v516_required))
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED",v516_reason,0,0.0,0.0,0.0,0.0,0.0,0.0,v516_required,v516_score,ExpansionPhase(ctx,direction,0.0),ExpansionLifecycleScore(ctx,direction),ExpansionDecayScore(ctx,direction),0.0,0.0,0.0,0.0,0.0);
      return;
   }
   else if(V516_AuditGatekeeperAllows)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","OBSERVE",v516_reason,0,0.0,0.0,0.0,0.0,0.0,0.0,v516_required,v516_score,ExpansionPhase(ctx,direction,0.0),ExpansionLifecycleScore(ctx,direction),ExpansionDecayScore(ctx,direction),0.0,0.0,0.0,0.0,0.0);
   }

   string mue_reason="";
   if(!MarketUnderstandingPasses(ctx,direction,mue_reason))
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED",mue_reason,0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,AdaptiveTransitionScore(ctx,direction),ExpansionPhase(ctx,direction,0.0),ExpansionLifecycleScore(ctx,direction),ExpansionDecayScore(ctx,direction),0.0,0.0,0.0,0.0,0.0);
      return;
   }

   string tsi_reason="";
   double tsi_score=0.0;
   double tsi_required=0.0;
   double tsi_death=0.0;
   if(!TradeSurvivalPasses(ctx,direction,idx,tsi_reason,tsi_score,tsi_required,tsi_death))
   {
      if(TradeSurvivalAuditBlocks)
         Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED",tsi_reason,0,0.0,0.0,0.0,0.0,0.0,0.0,tsi_required,tsi_score,ExpansionPhase(ctx,direction,0.0),ExpansionLifecycleScore(ctx,direction),tsi_death,0.0,0.0,0.0,0.0,0.0);
      return;
   }

   string risk_reason="";
   if(!RiskAllows(ctx.symbol,direction,idx,risk_reason))
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED",risk_reason,0,0.0,0.0,0.0,0.0);
      return;
   }

   if(!EnableRealEntries)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","SIGNAL_ONLY","REAL_ENTRIES_DISABLED",0,0.0,0.0,0.0,0.0);
      return;
   }

   double ask=SymbolInfoDouble(ctx.symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(ctx.symbol,SYMBOL_BID);
   double price=direction>0?ask:bid;

   double sl_distance=ctx.atr_now*SL_ATR_Multiplier;
   double asset_rr=AssetIdealRewardRiskRatio(ctx.symbol);
   double tp_distance=sl_distance*asset_rr; // V5.14B: TP base +12%; US500/US100 +14%; SL unchanged

   double rr_planned=SafeDiv(tp_distance,sl_distance,0.0);
   if(rr_planned < MinRewardRiskRatio)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED","RR_BELOW_MINIMUM",0,0.0,price,0.0,0.0,0.0,0.0,rr_planned,AdaptiveTransitionScore(ctx,direction));
      return;
   }

   double sl=0.0,tp=0.0;
   if(direction>0){ sl=price-sl_distance; tp=price+tp_distance; }
   else { sl=price+sl_distance; tp=price-tp_distance; }

   int digits=(int)SymbolInfoInteger(ctx.symbol,SYMBOL_DIGITS);
   sl=NormalizeDouble(sl,digits);
   tp=NormalizeDouble(tp,digits);
   price=NormalizeDouble(price,digits);

   double lots=CalculateRiskLot(ctx.symbol,sl_distance);
   double lot_boost=ContextLotBoost(ctx,direction);
   lots=lots*lot_boost;
   lots=NormalizeVolume(ctx.symbol,lots);
   lots=MarginSafeVolume(ctx.symbol,direction,lots,price);
   lots=NormalizeVolume(ctx.symbol,lots);

   double risk_money=CurrentRiskMoney();
   double expected_profit_money=ExpectedProfitMoneyByLot(ctx.symbol,tp_distance,lots);
   double lot_cap_symbol=SymbolLotCap(ctx.symbol);

   if(lots < MinLot)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED","MARGIN_SAFE_LOT_TOO_SMALL",0,lots,price,sl,tp,0.0,0.0,rr_planned,AdaptiveTransitionScore(ctx,direction),"",0.0,0.0,lot_cap_symbol,risk_money,expected_profit_money);
      return;
   }

   if(expected_profit_money < MinExpectedProfitMoney)
   {
      Audit(ctx,g_states[idx],direction,"DECISION","BLOCKED","EXPECTED_PROFIT_TOO_SMALL",0,lots,price,sl,tp,0.0,0.0,rr_planned,AdaptiveTransitionScore(ctx,direction),"",0.0,0.0,lot_cap_symbol,risk_money,expected_profit_money);
      return;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   bool ok=false;
   if(direction>0)
      ok=trade.Buy(lots,ctx.symbol,0.0,sl,tp,"V4.8 MRCE BUY");
   else
      ok=trade.Sell(lots,ctx.symbol,0.0,sl,tp,"V4.8 MRCE SELL");

   ulong ticket=trade.ResultOrder();
   string result=ok?"TRADE_OPENED":"TRADE_FAILED";
   string reason=ok?entry_reason:("ERR_"+IntegerToString((int)trade.ResultRetcode())+"_"+trade.ResultRetcodeDescription());

   if(ok)
   {
      g_total_trades_today++;
      g_states[idx].trades_today++;
      g_states[idx].state=TS_NORMAL;
      g_states[idx].state_direction=0;
      g_states[idx].state_age_bars=0;

      // V5.18: registrar memoria del trade abierto para aprender al cierre.
      ulong position_ticket=ticket;
      if(PositionSelect(ctx.symbol))
         position_ticket=(ulong)PositionGetInteger(POSITION_TICKET);
      V518RegisterTrade(position_ticket,ctx,direction,lots,price,sl,tp,v516_score,v516_required,v516_reason);
      ticket=position_ticket;
   }

   Audit(ctx,g_states[idx],direction,"EXECUTION",result,reason,ticket,lots,price,sl,tp,0.0,0.0,rr_planned,AdaptiveTransitionScore(ctx,direction),ExpansionPhase(ctx,direction,0.0),ExpansionLifecycleScore(ctx,direction),ExpansionDecayScore(ctx,direction),0.0,0.0,lot_cap_symbol,risk_money,expected_profit_money,
         (EnableV518LearningEngine && ok && V518_AuditLearningEntry ? "V518_ENTRY" : ""),v516_score,v516_required,v516_reason,DirectionConflictScore(ctx,direction),FalseExpansionRisk(ctx,direction),ImmediateDeathRiskScore(ctx,direction),0.0,0.0,"");
}

// ==================================================================
// TRANSITION STATE MACHINE
// ==================================================================
bool DirectionMeetsExpansion(MarketContext &ctx,int direction,DriverThresholds &d)
{
   double expansion=direction>0?ctx.expansion_buy:ctx.expansion_sell;
   double align=direction>0?ctx.direction_alignment_buy:ctx.direction_alignment_sell;
   double wick=direction>0?ctx.wick_risk_buy:ctx.wick_risk_sell;
   double strength=direction>0?ctx.strength_buy:ctx.strength_sell;
   double acceptance=direction>0?ctx.acceptance_buy:ctx.acceptance_sell;

   if(expansion>=d.expansion_min && align>=d.direction_align_min && wick<=d.wick_max)
      return true;

   if(IsIndexSymbol(ctx.symbol))
   {
      if(expansion>=d.expansion_min+0.04 && strength>=0.52 && wick<=d.wick_max && align>=d.direction_align_min-0.14)
         return true;

      if(expansion>=d.expansion_min+0.08 && acceptance>=d.acceptance_min+0.08 && wick<=d.wick_max)
         return true;
   }
   else
   {
      if(expansion>=d.expansion_min+0.06 && strength>=0.54 && wick<=d.wick_max && align>=d.direction_align_min-0.10)
         return true;
   }

   return false;
}

bool DirectionMeetsAcceptance(MarketContext &ctx,int direction,DriverThresholds &d)
{
   string reason="";
   return FinalEntryPasses(ctx,direction,d,reason);
}

void UpdateTransition(int idx,MarketContext &ctx)
{
   DriverThresholds d=GetDriver(ctx.symbol);
   SymbolState st=g_states[idx];

   st.state_age_bars++;

   if(st.state==TS_NORMAL)
   {
      if(ctx.compression_score>=d.compression_min)
      {
         st.state=TS_COMPRESSION;
         st.state_direction=0;
         st.state_age_bars=0;
         st.compression_time=ctx.signal_time;
         g_states[idx]=st;
         Audit(ctx,g_states[idx],0,"STATE","COMPRESSION_DETECTED","COMPRESSION_OK",0,0,0,0,0);
      }
      else
      {
         g_states[idx]=st;
         Audit(ctx,g_states[idx],0,"DECISION","NO_TRADE","WAIT_COMPRESSION",0,0,0,0,0);
      }
      return;
   }

   if(st.state==TS_COMPRESSION)
   {
      if(st.state_age_bars>CompressionExpireBars)
      {
         g_states[idx]=st;
         Audit(ctx,g_states[idx],0,"STATE","RESET","COMPRESSION_EXPIRED",0,0,0,0,0);
         st.state=TS_NORMAL;
         st.state_direction=0;
         st.state_age_bars=0;
         g_states[idx]=st;
         return;
      }

      bool buy_exp=DirectionMeetsExpansion(ctx,1,d);
      bool sell_exp=DirectionMeetsExpansion(ctx,-1,d);

      if(buy_exp || sell_exp)
      {
         int dir=0;
         if(buy_exp && sell_exp) dir=(ctx.score_buy>=ctx.score_sell ? 1 : -1);
         else if(buy_exp) dir=1;
         else dir=-1;

         st.state=TS_EXPANSION;
         st.state_direction=dir;
         st.state_age_bars=0;
         st.expansion_time=ctx.signal_time;
         g_states[idx]=st;
         Audit(ctx,g_states[idx],dir,"STATE","EXPANSION_DETECTED","AFTER_COMPRESSION",0,0,0,0,0);
      }
      else
      {
         g_states[idx]=st;
         Audit(ctx,g_states[idx],0,"DECISION","NO_TRADE","WAIT_EXPANSION_AFTER_COMPRESSION",0,0,0,0,0);
      }
      return;
   }

   if(st.state==TS_EXPANSION)
   {
      if(st.state_age_bars>ExpansionExpireBars)
      {
         g_states[idx]=st;
         Audit(ctx,g_states[idx],st.state_direction,"STATE","RESET","EXPANSION_EXPIRED",0,0,0,0,0);
         st.state=TS_NORMAL;
         st.state_direction=0;
         st.state_age_bars=0;
         g_states[idx]=st;
         return;
      }

      int dir=st.state_direction;
      if(DirectionMeetsAcceptance(ctx,dir,d))
      {
         st.state=TS_ACCEPTANCE;
         st.state_age_bars=0;
         g_states[idx]=st;
         Audit(ctx,g_states[idx],dir,"STATE","ACCEPTANCE_CONFIRMED","READY_TO_GLOBAL_RANKING",0,0,0,0,0);
         RegisterAssetCandidate(idx,ctx,dir,"COMPRESSION_EXPANSION_ACCEPTANCE");
      }
      else
      {
         g_states[idx]=st;
         Audit(ctx,g_states[idx],dir,"DECISION","NO_TRADE","WAIT_ACCEPTANCE",0,0,0,0,0);
      }
      return;
   }

   if(st.state==TS_ACCEPTANCE)
   {
      st.state=TS_NORMAL;
      st.state_direction=0;
      st.state_age_bars=0;
      g_states[idx]=st;
      return;
   }

   g_states[idx]=st;
}


// ==================================================================
// EXPANSION LIFECYCLE READER
// ==================================================================
double ExpansionLifecycleScore(MarketContext &ctx, int direction)
{
   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double room       = direction>0 ? ctx.volatility_room_buy : ctx.volatility_room_sell;
   double align      = direction>0 ? ctx.direction_alignment_buy : ctx.direction_alignment_sell;
   double strength   = direction>0 ? ctx.strength_buy : ctx.strength_sell;

   double score =
      expansion        * 18.0 +
      acceptance       * 18.0 +
      follow           * 18.0 +
      (1.0 - wick)     * 14.0 +
      (1.0 - rejection)* 10.0 +
      Clamp01(room)    * 8.0  +
      align            * 7.0  +
      strength         * 7.0;

   if(score < 0.0) score = 0.0;
   if(score > 100.0) score = 100.0;
   return score;
}

double ExpansionDecayScore(MarketContext &ctx, int direction)
{
   double expansion  = direction>0 ? ctx.expansion_buy : ctx.expansion_sell;
   double acceptance = direction>0 ? ctx.acceptance_buy : ctx.acceptance_sell;
   double follow     = direction>0 ? ctx.follow_buy : ctx.follow_sell;
   double wick       = direction>0 ? ctx.wick_risk_buy : ctx.wick_risk_sell;
   double rejection  = direction>0 ? ctx.rejection_buy : ctx.rejection_sell;
   double room       = direction>0 ? ctx.volatility_room_buy : ctx.volatility_room_sell;

   double decay =
      (1.0 - expansion)  * 22.0 +
      (1.0 - acceptance) * 18.0 +
      (1.0 - follow)    * 20.0 +
      wick              * 18.0 +
      rejection         * 14.0 +
      (1.0 - Clamp01(room)) * 8.0;

   if(decay < 0.0) decay = 0.0;
   if(decay > 100.0) decay = 100.0;
   return decay;
}

string ExpansionPhase(MarketContext &ctx, int direction, double r_now)
{
   double life = ExpansionLifecycleScore(ctx, direction);
   double decay = ExpansionDecayScore(ctx, direction);

   if(r_now < 0.80)
      return "EARLY";

   if(r_now >= LifecycleExhaustAtR && decay >= LifecycleDecayExitScore)
      return "EXHAUSTION";

   if(r_now >= LifecycleMatureAtR)
      return "MATURE";

   if(life >= 68.0 && decay < 55.0)
      return "DEVELOPMENT";

   if(decay >= LifecycleDecayExitScore)
      return "DECAY";

   return "TRANSITION";
}

bool ShouldLifecycleExit(MarketContext &ctx, int direction, double r_now, string &phase, double &life_score, double &decay_score)
{
   phase = ExpansionPhase(ctx, direction, r_now);
   life_score = ExpansionLifecycleScore(ctx, direction);
   decay_score = ExpansionDecayScore(ctx, direction);

   if(!UseExpansionLifecycleExit)
      return false;

   if(r_now >= LifecycleExhaustAtR && decay_score >= LifecycleDecayExitScore)
      return true;

   // If the trade is already profitable and the expansion quality collapses, monetize.
   if(r_now >= LifecycleProtectAtR && decay_score >= LifecycleDecayExitScore + 8.0)
      return true;

   return false;
}



// ==================================================================
// STRUCTURAL TRAILING HELPERS
// ==================================================================
double StructuralStopCandidate(string symbol, int direction, double atr)
{
   int bars = MathMax(StructuralSwingLookback + 2, 8);
   MqlRates r[];
   if(!LoadRates(symbol, InpDecisionTF, 1, bars, r))
      return 0.0;

   double buffer = atr * StructuralBufferATR;

   if(direction > 0)
   {
      double swing_low = DBL_MAX;
      for(int i=1; i<bars; i++)
         if(r[i].low < swing_low)
            swing_low = r[i].low;

      if(swing_low == DBL_MAX)
         return 0.0;

      return swing_low - buffer;
   }

   double swing_high = -DBL_MAX;
   for(int i=1; i<bars; i++)
      if(r[i].high > swing_high)
         swing_high = r[i].high;

   if(swing_high == -DBL_MAX)
      return 0.0;

   return swing_high + buffer;
}

double ProfitLockStopByR(long type, double open_price, double risk_price, double lock_r)
{
   if(risk_price <= 0.0)
      return 0.0;

   if(type == POSITION_TYPE_BUY)
      return open_price + risk_price * lock_r;

   if(type == POSITION_TYPE_SELL)
      return open_price - risk_price * lock_r;

   return 0.0;
}

double DesiredProtectedR(double r_now)
{
   if(r_now >= 5.0)
      return ProtectAt5R_LockR;

   if(r_now >= 3.0)
      return ProtectAt3R_LockR;

   if(r_now >= 2.0)
      return ProtectAt2R_LockR;

   if(r_now >= BreakEvenAtR)
      return BreakEvenLockR;

   return 0.0;
}

bool ApplyStructuralProtection(string symbol, long type, double open_price, double sl, double tp, double atr, double r_now, string phase, double &new_sl, double &protected_r)
{
   int direction = (type == POSITION_TYPE_BUY ? 1 : -1);
   double risk_price = PositionInitialRiskPrice(symbol, type, open_price, sl);
   if(risk_price <= 0.0)
      return false;

   protected_r = DesiredProtectedR(r_now);

   // Basic profit lock by R.
   double lock_sl = ProfitLockStopByR(type, open_price, risk_price, protected_r);

   // Structural trailing only when mature enough. This avoids capping normal development.
   double structural_sl = 0.0;
   if(UseStructuralTrailing && r_now >= StructuralTrailStartR)
   {
      if(!NoTrailingBeforeMature || phase == "MATURE" || phase == "DECAY" || phase == "EXHAUSTION")
         structural_sl = StructuralStopCandidate(symbol, direction, atr);
   }

   new_sl = lock_sl;

   if(structural_sl > 0.0)
   {
      if(type == POSITION_TYPE_BUY)
         new_sl = MathMax(lock_sl, structural_sl);
      else
      {
         if(lock_sl <= 0.0) new_sl = structural_sl;
         else new_sl = MathMin(lock_sl, structural_sl);
      }
   }

   bool improve = false;
   if(type == POSITION_TYPE_BUY && new_sl > sl && new_sl < SymbolInfoDouble(symbol, SYMBOL_BID))
      improve = true;

   if(type == POSITION_TYPE_SELL && (sl <= 0.0 || new_sl < sl) && new_sl > SymbolInfoDouble(symbol, SYMBOL_ASK))
      improve = true;

   return improve;
}



// ==================================================================
// V5.19/V5.20 — LIFECYCLE PROTECTOR DISABLED + OBSERVER ADVANCED
// ==================================================================
bool V519CanMoveStopTo(string symbol, long type, double current_sl, double new_sl)
{
   if(new_sl <= 0.0)
      return false;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   int stops    = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze   = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double min_distance = MathMax(stops, freeze) * point;

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   new_sl = NormalizeDouble(new_sl, digits);

   if(type == POSITION_TYPE_BUY)
   {
      if(new_sl <= current_sl)
         return false;
      if(new_sl >= bid - min_distance)
         return false;
      return true;
   }

   if(type == POSITION_TYPE_SELL)
   {
      if(current_sl > 0.0 && new_sl >= current_sl)
         return false;
      if(new_sl <= ask + min_distance)
         return false;
      return true;
   }

   return false;
}

bool V519ApplyLifecycleProtection(ulong ticket, string symbol, long type, double open_price, double initial_sl, double current_sl, double current_tp, double r_now, int bars_since_entry, double &new_sl, double &protected_r)
{
   if(!EnableV519LifecycleProtector)
      return false;

   if(initial_sl <= 0.0 || open_price <= 0.0)
      return false;

   if(r_now < V519_ProtectTriggerR)
      return false;

   if(V519_MinBarsAfterEntry > 0 && bars_since_entry < V519_MinBarsAfterEntry)
      return false;

   int mempos = V518FindMemoryByTicket(ticket);
   if(mempos < 0)
      mempos = V518FindMemoryBySymbol(symbol);

   if(mempos >= 0 && V519_ProtectOnlyOnce && g_v518_trades[mempos].v519_lifecycle_protected)
      return false;

   double risk_price = PositionInitialRiskPrice(symbol, type, open_price, initial_sl);
   if(risk_price <= 0.0)
      return false;

   protected_r = V519_ProtectLockR;
   new_sl = ProfitLockStopByR(type, open_price, risk_price, protected_r);

   if(!V519CanMoveStopTo(symbol, type, current_sl, new_sl))
      return false;

   return true;
}

void V519MarkLifecycleProtected(ulong ticket, string symbol)
{
   int mempos = V518FindMemoryByTicket(ticket);
   if(mempos < 0)
      mempos = V518FindMemoryBySymbol(symbol);
   if(mempos >= 0)
      g_v518_trades[mempos].v519_lifecycle_protected = true;
}

// ==================================================================
// POSITION MANAGEMENT
// ==================================================================
void AuditClose(string symbol, ulong ticket, double pnl, string reason, bool has_learning=false, double entry_reader_score=0.0, double entry_required_score=0.0, string entry_reader_reason="", double conflict=0.0, double false_expansion=0.0, double immediate_death=0.0, double mfe_r=0.0, double mae_r=0.0, string result_class="")
{
   MarketContext dummy;
   dummy.symbol=symbol;
   dummy.signal_time=TimeCurrent();
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dummy.hour_server=dt.hour; dummy.dow=dt.day_of_week; dummy.session_label=SessionLabel(dt.hour);
   dummy.signal_price=0; dummy.spread_points=0; dummy.dir_m5=0; dummy.dir_m15=0; dummy.dir_h1=0;
   dummy.score_buy=0; dummy.score_sell=0; dummy.regime_buy=""; dummy.regime_sell="";
   SymbolState st;
   st.symbol=symbol; st.state=TS_NORMAL; st.state_direction=0; st.trades_today=0;

   // V5.4: reconstrucción básica de dirección en cierres de broker.
   // En MT5, un deal SELL que cierra posición normalmente corresponde a entrada BUY;
   // un deal BUY que cierra posición normalmente corresponde a entrada SELL.
   int close_direction=0;
   long deal_type=HistoryDealGetInteger(ticket,DEAL_TYPE);
   if(deal_type==DEAL_TYPE_SELL) close_direction=1;
   else if(deal_type==DEAL_TYPE_BUY) close_direction=-1;

   Audit(dummy,st,close_direction,"CLOSE","POSITION_CLOSED",reason,ticket,0,0,0,0,pnl,0.0,0.0,0.0,"",0.0,0.0,0.0,0.0,0.0,0.0,0.0,
         (has_learning ? "V518_CLOSE" : ""),entry_reader_score,entry_required_score,entry_reader_reason,conflict,false_expansion,immediate_death,mfe_r,mae_r,result_class);
}

void ManagePositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      long magic=PositionGetInteger(POSITION_MAGIC);
      if((ulong)magic!=MagicNumber) continue;

      string symbol=PositionGetString(POSITION_SYMBOL);
      datetime open_time=(datetime)PositionGetInteger(POSITION_TIME);
      double pnl=PositionGetDouble(POSITION_PROFIT);
      long type=PositionGetInteger(POSITION_TYPE);
      double open_price=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double volume=PositionGetDouble(POSITION_VOLUME);

      // V5.19: medir R siempre contra el SL inicial registrado por V5.18.
      // Si se modifica el SL para proteger vida del trade, no debe deformar el cálculo de R.
      double initial_sl_for_r = sl;
      int v518_mempos = V518FindMemoryByTicket(ticket);
      if(v518_mempos < 0)
         v518_mempos = V518FindMemoryBySymbol(symbol);
      if(v518_mempos >= 0 && g_v518_trades[v518_mempos].sl > 0.0)
         initial_sl_for_r = g_v518_trades[v518_mempos].sl;

      double risk_price=PositionInitialRiskPrice(symbol,type,open_price,initial_sl_for_r);
      double r_now=CurrentRMultiple(symbol,type,open_price,initial_sl_for_r);
      int direction=(type==POSITION_TYPE_BUY ? 1 : -1);

      // V5.18/V5.19: mide recorrido máximo favorable/adverso sin contaminar el R original.
      V518UpdateOpenTrade(ticket,symbol,direction,r_now);

      int idx=FindSymbolIndex(symbol);
      MarketContext ctx;
      bool has_ctx=false;
      if(idx>=0)
         has_ctx=BuildContext(idx,ctx);

      string phase="";
      double life_score=0.0;
      double decay_score=0.0;
      double atr=0.0;

      if(has_ctx)
      {
         phase=ExpansionPhase(ctx,direction,r_now);
         life_score=ExpansionLifecycleScore(ctx,direction);
         decay_score=ExpansionDecayScore(ctx,direction);
         atr=ctx.atr_now;
      }
      else if(idx>=0)
      {
         atr=BufferValue(g_states[idx].h_atr_decision,0,1);
      }

      // V5.20 — Lifecycle Observer Advanced: observa niveles 0.5R/1R/2R/3R y pullback, sin tocar la operación.
      if(has_ctx && idx>=0)
         V520ObserveLifecycle(ticket,symbol,direction,volume,pnl,r_now,ctx,g_states[idx],phase,life_score,decay_score);

      // V5.19 — Lifecycle Protection: en V5.20 está desactivado por defecto.
      int bars_since_entry=iBarShift(symbol,InpDecisionTF,open_time,false);
      if(risk_price>0.0)
      {
         double v519_new_sl=0.0;
         double v519_protected_r=0.0;
         if(V519ApplyLifecycleProtection(ticket,symbol,type,open_price,initial_sl_for_r,sl,tp,r_now,bars_since_entry,v519_new_sl,v519_protected_r))
         {
            bool ok=ModifyPositionStops(symbol,v519_new_sl,tp);
            if(ok)
            {
               V519MarkLifecycleProtected(ticket,symbol);
               if(V519_AuditProtection && has_ctx && idx>=0)
                  Audit(ctx,g_states[idx],direction,"MANAGE","SL_MODIFIED","V519_LIFECYCLE_PROTECTOR_1R",ticket,volume,0.0,v519_new_sl,tp,pnl,r_now,0.0,0.0,phase,life_score,decay_score,v519_new_sl,v519_protected_r);
            }
         }
      }

      // 1) Structural protection replaces premature ATR trailing.
      // It locks profit by R and only trails structure after maturity.
      if(AllowStopModification && risk_price>0.0 && atr>0.0 && r_now>=BreakEvenAtR)
      {
         double new_sl=0.0;
         double protected_r=0.0;

         if(ApplyStructuralProtection(symbol,type,open_price,sl,tp,atr,r_now,phase,new_sl,protected_r))
         {
            bool ok=ModifyPositionStops(symbol,new_sl,tp);

            if(ok && has_ctx && idx>=0)
               Audit(ctx,g_states[idx],direction,"MANAGE","SL_MODIFIED","STRUCTURAL_PROTECTION",ticket,volume,0.0,new_sl,tp,pnl,r_now,0.0,0.0,phase,life_score,decay_score,new_sl,protected_r);
         }
      }

      // 2) Lifecycle exit: only exit when there is real decay/exhaustion.
      // V3.0 is less aggressive than V2.9, to avoid capping winners too early.
      if(has_ctx)
      {
         string exit_phase="";
         double exit_life=0.0;
         double exit_decay=0.0;

         if(ShouldLifecycleExit(ctx,direction,r_now,exit_phase,exit_life,exit_decay))
         {
            bool allow_exit = false;

            if(exit_phase=="EXHAUSTION" && r_now>=LifecycleExhaustAtR)
               allow_exit = true;

            if(exit_phase=="DECAY" && r_now>=3.0 && exit_decay>=LifecycleDecayExitScore+10.0)
               allow_exit = true;

            if(allow_exit)
            {
               trade.SetExpertMagicNumber(MagicNumber);
               bool ok=trade.PositionClose(symbol);
               if(ok)
               {
                  Audit(ctx,g_states[idx],direction,"CLOSE","POSITION_CLOSED","STRUCTURAL_LIFECYCLE_"+exit_phase,ticket,volume,0.0,sl,tp,pnl,r_now,0.0,0.0,exit_phase,exit_life,exit_decay,0.0,DesiredProtectedR(r_now));
                  continue;
               }
            }
         }

         // 3) Weakness exit only after 3R. Before that, protect structure, do not cap.
         if(r_now>=3.0 && ShouldExitByWeakness(ctx,direction))
         {
            trade.SetExpertMagicNumber(MagicNumber);
            bool ok=trade.PositionClose(symbol);
            if(ok)
            {
               Audit(ctx,g_states[idx],direction,"CLOSE","POSITION_CLOSED","WEAKNESS_EXIT_"+phase,ticket,volume,0.0,sl,tp,pnl,r_now,0.0,0.0,phase,life_score,decay_score,0.0,DesiredProtectedR(r_now));
               continue;
            }
         }
      }

      // 4) Stagnation exit: unchanged, but only if no meaningful development.
      int shift=bars_since_entry;
      if(shift>=StagnationBarsAfterEntry && r_now<StagnationMinR)
      {
         trade.SetExpertMagicNumber(MagicNumber);
         bool ok=trade.PositionClose(symbol);
         if(ok)
         {
            if(has_ctx && idx>=0)
               Audit(ctx,g_states[idx],direction,"CLOSE","POSITION_CLOSED","STAGNATION_EXIT",ticket,volume,0.0,sl,tp,pnl,r_now,0.0,0.0,phase,life_score,decay_score,0.0,0.0);
            else
               AuditClose(symbol,ticket,pnl,"STAGNATION_EXIT");
            continue;
         }
      }

      // 5) Time exit as last resort.
      if(shift>=MaxHoldBars && MaxHoldBars>0)
      {
         trade.SetExpertMagicNumber(MagicNumber);
         bool ok=trade.PositionClose(symbol);
         if(ok)
         {
            if(has_ctx && idx>=0)
               Audit(ctx,g_states[idx],direction,"CLOSE","POSITION_CLOSED","TIME_EXIT_"+phase,ticket,volume,0.0,sl,tp,pnl,r_now,0.0,0.0,phase,life_score,decay_score,0.0,DesiredProtectedR(r_now));
            else
               AuditClose(symbol,ticket,pnl,"TIME_EXIT");
         }
         Print("[V4.4] Time exit symbol=",symbol," ok=",ok," ret=",trade.ResultRetcodeDescription());
      }
   }
}

// ==================================================================
// BAR CONTROL
// ==================================================================
bool IsNewBar(int idx)
{
   string symbol=g_states[idx].symbol;
   datetime t=iTime(symbol,InpDecisionTF,0);
   if(t<=0) return false;
   if(g_states[idx].last_bar_time!=t)
   {
      g_states[idx].last_bar_time=t;
      return true;
   }
   return false;
}

// ==================================================================
// LIFECYCLE
// ==================================================================
int OnInit()
{
   SplitSymbolsAndInit();

   if(!OpenCSV())
      return INIT_FAILED;

   g_initial_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_day_start_equity=g_initial_equity;
   g_peak_equity=g_initial_equity;
   g_equity_lock_floor=g_initial_equity;
   g_max_balance_seen=g_initial_equity;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   g_day_of_year=dt.day_of_year;
   g_total_trades_today=0;

   Print("[EA_ACTIVE] EA_Maestro_V5_20_LIFECYCLE_OBSERVER_ADVANCED");
   Print("[CSV_FILE] ",InpOutputCSV);
   Print("[RUN_SIGNATURE] ",InpRunId);
   Print("[V5.4] Symbols loaded: ",ArraySize(g_states));
   Print("[V5.4] REAL ENTRIES ENABLED=",EnableRealEntries);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   CloseCSV();
   ReleaseAll();
   Print("[V5.4] rows_written=",g_rows_written);
   Print("[V5.4] deinit_reason=",reason);
}


void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0)
      return;

   if(!HistoryDealSelect(deal))
      return;

   long magic = (long)HistoryDealGetInteger(deal,DEAL_MAGIC);
   if((ulong)magic != MagicNumber)
      return;

   long entry = HistoryDealGetInteger(deal,DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   string symbol = HistoryDealGetString(deal,DEAL_SYMBOL);
   double profit = HistoryDealGetDouble(deal,DEAL_PROFIT)
                 + HistoryDealGetDouble(deal,DEAL_SWAP)
                 + HistoryDealGetDouble(deal,DEAL_COMMISSION);

   int sidx=SymbolIndexByName(symbol);
   if(sidx>=0)
   {
      if(profit<0.0)
      {
         g_states[sidx].consecutive_losses++;
         if(EnableAdaptiveCooldown && g_states[sidx].consecutive_losses>=MaxConsecutiveLossesAsset)
         {
            int seconds=PeriodSeconds(InpDecisionTF)*CooldownBarsAfterLosses;
            g_states[sidx].cooldown_until=TimeCurrent()+seconds;
            g_states[sidx].consecutive_losses=0;
         }
      }
      else if(profit>0.0)
      {
         g_states[sidx].consecutive_losses=0;
      }
   }

   UpdateEquityLock();

   string reason = "BROKER_DEAL_CLOSE";
   long deal_reason = HistoryDealGetInteger(deal,DEAL_REASON);

   if(deal_reason == DEAL_REASON_SL)
      reason = "BROKER_SL_CLOSE";
   else if(deal_reason == DEAL_REASON_TP)
      reason = "BROKER_TP_CLOSE";
   else if(deal_reason == DEAL_REASON_CLIENT)
      reason = "MANUAL_OR_EA_CLOSE";
   else if(deal_reason == DEAL_REASON_EXPERT)
      reason = "EA_CLOSE";

   ulong position_id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   V518TradeMemory mem;
   bool has_learning=V518GetAndDeactivate(symbol,position_id,mem);

   double close_r=0.0;
   string result_class="";
   if(has_learning)
   {
      if(mem.direction>0)
         close_r=CurrentRMultiple(symbol,POSITION_TYPE_BUY,mem.entry_price,mem.sl);
      else
         close_r=CurrentRMultiple(symbol,POSITION_TYPE_SELL,mem.entry_price,mem.sl);
      result_class=V518ResultClass(close_r,profit);
   }

   AuditClose(symbol,deal,profit,reason,has_learning,
              (has_learning ? mem.entry_reader_score : 0.0),
              (has_learning ? mem.entry_required_score : 0.0),
              (has_learning ? mem.entry_reader_reason : ""),
              (has_learning ? mem.entry_conflict : 0.0),
              (has_learning ? mem.entry_false_expansion : 0.0),
              (has_learning ? mem.entry_immediate_death : 0.0),
              (has_learning ? mem.mfe_r : 0.0),
              (has_learning ? mem.mae_r : 0.0),
              result_class);
}


void OnTick()
{
   ManagePositions();
   ResetDailyCountersIfNeeded();
   ResetCandidates();

   for(int i=0;i<ArraySize(g_states);i++)
   {
      if(!IsNewBar(i)) continue;

      MarketContext ctx;
      if(!BuildContext(i,ctx)) continue;

      UpdateTransition(i,ctx);
   }

   ExecuteBestCandidate();
}
//+------------------------------------------------------------------+
