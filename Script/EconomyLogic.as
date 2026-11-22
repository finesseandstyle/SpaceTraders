// EconomyLogic.as
//
// Global economy tuning, trade-good rules and trade legality/production rules.
//
// Replaces:
//   UEconomyGlobalConfig (data asset)  -> the constants below
//   DT_TradeGoods / FTradeGood row     -> GetTradeGoodRules()
//   SupplyChainInputs (was copied into -> GetSupplyChainInputs()
//     every FGlobalTradeGoodStatus)
//   UTradeLogic (C++ library)          -> the functions at the bottom of this file
//
// Everything is a namespace-level constant or function, so any script can read it
// without holding a reference, and editing a value here and saving hot-reloads it.
// Runtime state (prices, supply, fluctuation, markets) does NOT belong here; that
// lives on the TRS (see TurnResolutionSubsystem.as).

// Static trading rules for one trade good (was a DT_TradeGoods row).
// The icon is intentionally gone: use the general item definition query for that.
struct FTradeGoodRules
{
    UPROPERTY() float BasePrice = 0.0;
    UPROPERTY() float BaseRange = 0.0;
    UPROPERTY() float VolatilityPrice = 0.0;
    UPROPERTY() int VolatilityDuration = 0;

    FTradeGoodRules() {}

    FTradeGoodRules(float InBasePrice, float InBaseRange, float InVolatilityPrice, int InVolatilityDuration)
    {
        BasePrice = InBasePrice;
        BaseRange = InBaseRange;
        VolatilityPrice = InVolatilityPrice;
        VolatilityDuration = InVolatilityDuration;
    }
};

enum ETradeGoodType
{
    EssentialGoods      UMETA(DisplayName = "Essential Goods"),
    Medicine            UMETA(DisplayName = "Medicine"),
    Organics            UMETA(DisplayName = "Organics"),
    Synthetics          UMETA(DisplayName = "Synthetics"),
    CommonMinerals      UMETA(DisplayName = "Common Minerals"),
    RareMinerals        UMETA(DisplayName = "Rare Minerals"),
    RefinedMinerals     UMETA(DisplayName = "Refined Minerals"),
    ViceGoods           UMETA(DisplayName = "Vice Goods"),
    Microchips          UMETA(DisplayName = "Microchips"),
    ConsumerTech        UMETA(DisplayName = "Consumer Tech"),
    HeavyMachinery      UMETA(DisplayName = "Heavy Machinery"),
    LuxuryGoods         UMETA(DisplayName = "Luxury Goods"),
    Fuel                UMETA(DisplayName = "Fuel"),
    Ammunition          UMETA(DisplayName = "Ammunition"),
    EquipmentParts      UMETA(DisplayName = "Equipment Parts"),
    Weapons             UMETA(DisplayName = "Weapons"),
    Narcotics           UMETA(DisplayName = "Narcotics"),
    NoType              UMETA(DisplayName = "No Type")
};

// ------------------ Races ------------------
enum ERaceType
{
    Maloq       UMETA(DisplayName = "Maloq"),
    Peleng      UMETA(DisplayName = "Peleng"),
    Human       UMETA(DisplayName = "Human"),
    Faeyan      UMETA(DisplayName = "Faeyan"),
    Gaalian     UMETA(DisplayName = "Gaalian")
};

// ------------------ Political Systems ------------------
enum EPoliticalSystem
{
    Democracy       UMETA(DisplayName = "Democracy"),
    Oligarchy       UMETA(DisplayName = "Oligarchy"),
    Dictatorship    UMETA(DisplayName = "Dictatorship"),
    Monarchy        UMETA(DisplayName = "Monarchy"),
    Anarchy         UMETA(DisplayName = "Anarchy"),
    Theocracy       UMETA(DisplayName = "Theocracy")
};

// ------------------ Economy Types ------------------
enum EEconomyType
{
    Agrarian    UMETA(DisplayName = "Agrarian"),
    Mixed       UMETA(DisplayName = "Mixed"),
    Industrial  UMETA(DisplayName = "Industrial"),
    Extractive  UMETA(DisplayName = "Extractive"),
    Resort      UMETA(DisplayName = "Resort")
};

enum EEconomySituation
{
    Balanced       UMETA(DisplayName = "Balanced"),
    Deficit        UMETA(DisplayName = "Deficit"),
    MajorDeficit   UMETA(DisplayName = "Major Deficit"),
    Surplus        UMETA(DisplayName = "Surplus"),
    MajorSurplus   UMETA(DisplayName = "Major Surplus")
};

// ------------------ Structs ------------------

// Per-good state shared by every market: static values copied from
// EconomyLogic::GetTradeGoodRules at init, plus the fluctuation state that evolves over time.
struct FGlobalTradeGoodStatus
{
    UPROPERTY() float BasePrice = 0.0;
    UPROPERTY() float BaseProduction = 0.0;
    UPROPERTY() float BaseRange = 0.0;
    UPROPERTY() float MaxFluctuation = 0.0;
    UPROPERTY() float CurrentFluctuation = 0.0;
    UPROPERTY() float VolatilityDuration = 0.0;
    UPROPERTY() float VolatilityTimer = 0.0;
    UPROPERTY() float PreviousFluctuation = 0.0;
    UPROPERTY() float TargetFluctuation = 0.0;
};

struct FProducerModifier
{
    UPROPERTY() float PriceModifier = 1.0;
    UPROPERTY() float SupplyModifier = 1.0;
};

struct FTradeModifier
{
    UPROPERTY() FName ModifierName;
    UPROPERTY() float PriceModifier = 1.0;
    UPROPERTY() float SupplyModifier = 1.0;
};

// One trade good inside one market.
struct FMarketGoodStatus
{
    UPROPERTY() bool bIsEssential = false;
    UPROPERTY() bool bIsLegal = true;
    UPROPERTY() float Equilibrium = 1000.0;
    UPROPERTY() float Supply = 1000.0;
    UPROPERTY() float CirculatingQuantity = 0.0;
    UPROPERTY() float BuyPricePoint = 0.0;
    UPROPERTY() float SellPricePoint = 0.0;
    UPROPERTY() float BuyPrice = 0.0;
    UPROPERTY() float SellPrice = 0.0;
    UPROPERTY() float LastBuySupply = 1000.0;
    UPROPERTY() float LastSellSupply = 1000.0;
    UPROPERTY() float SupplyRatio = 1.0;
    UPROPERTY() EEconomySituation Situation;
    UPROPERTY() TArray<FTradeModifier> BuyModifiers;
    UPROPERTY() TArray<FTradeModifier> SellModifiers;
    UPROPERTY() TMap<FName, float> OriginModifiers;
};

struct FTradeGoodStack
{
    UPROPERTY() int32 Quantity = 0;
    UPROPERTY() FText Origin;
    UPROPERTY() FText Producer;
    UPROPERTY() int32 PurchasedPrice = 0;
};

struct FProducer
{
    UPROPERTY() FName Name;
    UPROPERTY() ERaceType Race;
    UPROPERTY() TMap<FName, FProducerModifier> TradeGoodModifiers;
};

// Each market has a list of producers which influence supply/demand/prices
struct FMarket
{
    UPROPERTY() FName Name;
    UPROPERTY() ERaceType Race;
    UPROPERTY() EEconomyType EconomyType;
    UPROPERTY() EPoliticalSystem PoliticalSystem;
    UPROPERTY() float PopulationMillions = 0.0;
    UPROPERTY() TArray<FMarketGoodStatus> MarketGoods;
    UPROPERTY() TArray<int32> ProducerIndexes; // We create a global list of producers and then assign to markets the indexes
};

// How many producers spawn for a trade good (was a DT_ProducerSpawnRules row).
// Modifiers are added to BaseAmount; use GetSpawnCount().
struct FProducerSpawnRules
{
    UPROPERTY() int BaseAmount = 0;

    UPROPERTY() int PoliticsTheocracy = 0;
    UPROPERTY() int PoliticsAnarchy = 0;
    UPROPERTY() int PoliticsMonarchy = 0;
    UPROPERTY() int PoliticsDictatorship = 0;
    UPROPERTY() int PoliticsOligarchy = 0;
    UPROPERTY() int PoliticsDemocracy = 0;

    UPROPERTY() int DevelopmentExtractive = 0;
    UPROPERTY() int DevelopmentIndustrial = 0;
    UPROPERTY() int DevelopmentMixed = 0;
    UPROPERTY() int DevelopmentAgrarian = 0;

    FProducerSpawnRules() {}

    // Argument order matches the CSV columns, so rows can be checked against it line by line.
    FProducerSpawnRules(int InBaseAmount,
        int InTheocracy, int InAnarchy, int InMonarchy, int InDictatorship, int InOligarchy, int InDemocracy,
        int InExtractive, int InIndustrial, int InMixed, int InAgrarian)
    {
        BaseAmount = InBaseAmount;

        PoliticsTheocracy = InTheocracy;
        PoliticsAnarchy = InAnarchy;
        PoliticsMonarchy = InMonarchy;
        PoliticsDictatorship = InDictatorship;
        PoliticsOligarchy = InOligarchy;
        PoliticsDemocracy = InDemocracy;

        DevelopmentExtractive = InExtractive;
        DevelopmentIndustrial = InIndustrial;
        DevelopmentMixed = InMixed;
        DevelopmentAgrarian = InAgrarian;
    }

    int GetPoliticsModifier(EPoliticalSystem Politics) const
    {
        switch (Politics)
        {
            case EPoliticalSystem::Theocracy:    return PoliticsTheocracy;
            case EPoliticalSystem::Anarchy:      return PoliticsAnarchy;
            case EPoliticalSystem::Monarchy:     return PoliticsMonarchy;
            case EPoliticalSystem::Dictatorship: return PoliticsDictatorship;
            case EPoliticalSystem::Oligarchy:    return PoliticsOligarchy;
            case EPoliticalSystem::Democracy:    return PoliticsDemocracy;
        }
    }

    int GetDevelopmentModifier(EEconomyType Economy) const
    {
        switch (Economy)
        {
            case EEconomyType::Extractive: return DevelopmentExtractive;
            case EEconomyType::Industrial: return DevelopmentIndustrial;
            case EEconomyType::Mixed:      return DevelopmentMixed;
            case EEconomyType::Agrarian:   return DevelopmentAgrarian;
            default:                       return 0;
        }
    }

    // ASSUMPTION: modifiers are additive and the result is floored at 0 (the -10
    // Theocracy entries read as "none"). Change this if you combine them differently.
    int GetSpawnCount(EPoliticalSystem Politics, EEconomyType Economy) const
    {
        return Math::Max(0, BaseAmount + GetPoliticsModifier(Politics) + GetDevelopmentModifier(Economy));
    }
};


namespace EconomyLogic
{
    // ==================================================================
    // Core
    // ==================================================================

    // Base value to generate goods on a market
    const float BaseProduction = 50.0;

    // Lower values = tighter profit margins, Default is 1. Recommended use is between 0.5 and 1.0
    const float TradeDifficulty = 1.0;

    // ==================================================================
    // Logistics
    // ==================================================================

    // These next 3 settings have the greatest effect on amount of profitable trades, affects minimum and maximum prices of trade goods.
    // Higher values result in a more pronounced logistic S-Curve making prices change sharply at the middle.
    // Lower values result in a more linear curve.
    const float BuyLogisticFactor = 3.0;
    const float SellLogisticFactor = 2.9;

    // Ensures min and max prices of the logistic curve can be realistically reached. Not recommended higher than 0.05
    const float LogisticCutoff = 0.025;

    // Ensures sell prices are not too far away from buy prices, keep the values between 1.0-2.0
    const float SellCenterShift = 1.6;

    // Lowest discount (when surplus is at max)
    const float SellMinDiscount = 0.15;

    // Highest discount (when deficit is at max)
    const float SellMaxDiscount = 0.95;

    // ==================================================================
    // Supply
    // ==================================================================

    // Changing these next 4 doesn't seem to have a great effect on anything
    const float DeficitSupplyRatio = 0.75;
    const float MajorDeficitSupplyRatio = 0.2;
    const float SurplusSupplyRatio = 1.25;
    const float MajorSurplusSupplyRatio = 2.0;

    // Determines base amount of units bought or sold that result in a price update
    // Example BreakpointDividend / Base Price of Essential Goods = 7000 / 22 = ~318
    // Then we round this number nicely to 300. Every 300 units, price of essential goods updates.
    const float BreakpointDividend = 7000.0;

    // ==================================================================
    // Inflation
    // ==================================================================

    // How many days it takes from day 1 to reach max inflation
    const int MaxInflationDays = 10000;

    // Global price multiplier
    const float MaxInflation = 4.0;

    // ==================================================================
    // Market
    // ==================================================================

    // Higher interval - lower average profits, small effect
    const float LowerDevelopmentScore = 0.8;
    const float UpperDevelopmentScore = 1.2;

    // Increases equilibrium, the amount of large volume trades, and decreases their average profitability
    const float BaseTradeGoodsAmount = 10000.0;

    // Doesn't seem to have a great effect on anything
    const float EquilibriumVariance = 0.25;

    // Greatly affect amount of profitable trades and profitability
    const float LowSupplySpread = 0.1;
    const float HighSupplySpread = 1.9;

    // Next 3 have significant effect amount of profitable trades and profitability
    const float InterstellarPriceSpread = 0.20;
    const float EnterprisePriceSpread = 0.25;
    const float IndividualPriceSpread = 0.40;

    // When updating, how much LastBuySupply and LastSellSupply drift towards TotalSupply
    const float PriceDriftingFactor = 0.1;

    // Share of quantities that are circulating (not available yet) that transfer into available quantities
    // When selling, this quantity is increased for buy orders
    const float CirculatingBuyBalancingFactor = 0.2;

    // When buying, this is used to add circulating quantity for sell orders
    const float CirculatingSellBalancingFactor = 0.075;

    // Share of circulating quantity on a trade good that will remain on turn update
    const float CirculatingRetentionRate = 0.9;

    // Do not make this value larger than (1 - Retention) / Retention
    const float CirculatingDecayRate = 0.075;

    // ==================================================================
    // Trade goods
    // ==================================================================

    // Every ETradeGoodType before NoType (NoType must stay last in the enum).
    const int TradeGoodCount = int(ETradeGoodType::NoType);

    // Static rules per trade good. One row per good, keyed by enum, so ordering
    // can never drift out of sync with ETradeGoodType the way DT row order could.
    //BasePrice  BaseRange  VolatilityPrice  VolatilityDuration     
    UFUNCTION(BlueprintPure)
    FTradeGoodRules GetTradeGoodRules(ETradeGoodType TradeGood)
    {
        switch (TradeGood)
        {
            case ETradeGoodType::EssentialGoods:  return FTradeGoodRules(  22.0, 0.450,  3.0, 12);
            case ETradeGoodType::Medicine:        return FTradeGoodRules(  30.0, 0.350,  1.0, 50);
            case ETradeGoodType::Organics:        return FTradeGoodRules(  17.0, 0.475,  3.0, 10);
            case ETradeGoodType::Synthetics:      return FTradeGoodRules(  13.0, 0.350,  1.0, 45);
            case ETradeGoodType::CommonMinerals:  return FTradeGoodRules(   9.0, 0.450,  2.0, 90);
            case ETradeGoodType::RareMinerals:    return FTradeGoodRules(  40.0, 0.475,  7.0, 25);
            case ETradeGoodType::RefinedMinerals: return FTradeGoodRules(  25.0, 0.350,  3.0, 50);
            case ETradeGoodType::ViceGoods:       return FTradeGoodRules(  30.0, 0.500,  5.0, 10);
            case ETradeGoodType::Microchips:      return FTradeGoodRules(  50.0, 0.300,  4.0, 50);
            case ETradeGoodType::ConsumerTech:    return FTradeGoodRules(  60.0, 0.400,  4.0, 35);
            case ETradeGoodType::HeavyMachinery:  return FTradeGoodRules(2000.0, 0.250, 50.0, 50);
            case ETradeGoodType::LuxuryGoods:     return FTradeGoodRules( 150.0, 0.350, 35.0, 30);
            case ETradeGoodType::Fuel:            return FTradeGoodRules(  10.0, 0.300,  1.0, 15);
            case ETradeGoodType::Ammunition:      return FTradeGoodRules(  15.0, 0.300,  2.0, 20);
            case ETradeGoodType::EquipmentParts:  return FTradeGoodRules(  90.0, 0.200,  3.0, 25);
            case ETradeGoodType::Weapons:         return FTradeGoodRules(  75.0, 0.450, 10.0, 20);
            case ETradeGoodType::Narcotics:       return FTradeGoodRules( 300.0, 0.500, 60.0,  5);
            default:                              return FTradeGoodRules();
        }
    }

    // Goods required to produce this good. Kept out of FGlobalTradeGoodStatus so
    // that struct stays plain floats (cheap to copy on every price calculation).
    UFUNCTION(BlueprintPure)
    TArray<ETradeGoodType> GetSupplyChainInputs(ETradeGoodType TradeGood)
    {
        TArray<ETradeGoodType> Inputs;

        switch (TradeGood)
        {
            case ETradeGoodType::EssentialGoods:
            case ETradeGoodType::Medicine:
            case ETradeGoodType::ViceGoods:
                Inputs.Add(ETradeGoodType::Organics);
                Inputs.Add(ETradeGoodType::Synthetics);
                break;

            case ETradeGoodType::RefinedMinerals:
                Inputs.Add(ETradeGoodType::CommonMinerals);
                Inputs.Add(ETradeGoodType::RareMinerals);
                break;

            case ETradeGoodType::Microchips:
            case ETradeGoodType::LuxuryGoods:
            case ETradeGoodType::Ammunition:
            case ETradeGoodType::Weapons:
                Inputs.Add(ETradeGoodType::RefinedMinerals);
                Inputs.Add(ETradeGoodType::Synthetics);
                break;

            case ETradeGoodType::ConsumerTech:
                Inputs.Add(ETradeGoodType::Microchips);
                Inputs.Add(ETradeGoodType::Synthetics);
                break;

            case ETradeGoodType::HeavyMachinery:
                Inputs.Add(ETradeGoodType::EquipmentParts);
                Inputs.Add(ETradeGoodType::Synthetics);
                Inputs.Add(ETradeGoodType::RefinedMinerals);
                break;

            case ETradeGoodType::EquipmentParts:
                Inputs.Add(ETradeGoodType::Microchips);
                Inputs.Add(ETradeGoodType::Synthetics);
                Inputs.Add(ETradeGoodType::RefinedMinerals);
                break;

            case ETradeGoodType::Narcotics:
                Inputs.Add(ETradeGoodType::CommonMinerals);
                Inputs.Add(ETradeGoodType::Organics);
                Inputs.Add(ETradeGoodType::Synthetics);
                break;

            default: break;
            // Organics, Synthetics, CommonMinerals, RareMinerals, Fuel: raw goods, no inputs
        }

        return Inputs;
    }

    // What trade goods are essential for each race (was EssentialGoodsByRace on the data asset).
    // TODO: fill these in from your old economy config asset. They were set in the
    // editor, so the values weren't in the C++ source I had. Until filled,
    // IsEssential() returns false for everything.
    // e.g.  Goods.Add(ETradeGoodType::EssentialGoods);
    TArray<ETradeGoodType> GetEssentialGoods(ERaceType Race)
    {
        TArray<ETradeGoodType> Goods;

        switch (Race)
        {
            case ERaceType::Maloq:   break;
            case ERaceType::Peleng:  break;
            case ERaceType::Human:   break;
            case ERaceType::Faeyan:  break;
            case ERaceType::Gaalian: break;
        }

        return Goods;
    }

    // ==================================================================
    // Trade rules (formerly UTradeLogic)
    // ==================================================================

    float GetConsumptionMultiplier(
        ERaceType Race,
        EEconomyType Economy,
        EPoliticalSystem PoliticalSystem,
        ETradeGoodType TradeGood,
        float SupplyRatio)
    {
        float Multiplier = 1.0;

        if (SupplyRatio <= MajorDeficitSupplyRatio)
            Multiplier *= 0.2; // demand collapses, rationing is imposed

        // Economy type
        switch (Economy)
        {
            case EEconomyType::Industrial: Multiplier *= 1.3; break;
            case EEconomyType::Mixed:      Multiplier *= 1.0; break;
            case EEconomyType::Agrarian:   Multiplier *= 0.8; break;
            case EEconomyType::Extractive: Multiplier *= 0.7; break;
            default: Multiplier *= 0.7;
        }

        if (TradeGood == ETradeGoodType::EssentialGoods)
            Multiplier *= (Race == ERaceType::Maloq) ? 1.5 : 1.0;

        // Trade good specific consumption
        if (TradeGood == ETradeGoodType::LuxuryGoods)
        {
            if (Race == ERaceType::Peleng) Multiplier *= 2.0;
            else if (Race == ERaceType::Human) Multiplier *= 1.5;
            else if (Race == ERaceType::Faeyan) Multiplier *= 1.3;
        }

        if (TradeGood == ETradeGoodType::ViceGoods)
        {
            if (Race == ERaceType::Human) Multiplier *= 1.5;
            if (Race == ERaceType::Peleng) Multiplier *= 1.3;
        }

        return Multiplier;
    }

    float GetProductionMultiplier(
        ERaceType Race,
        EEconomyType Economy,
        EPoliticalSystem PoliticalSystem,
        ETradeGoodType TradeGood,
        float SupplyRatio,
        float SupplyChainMultiplier,
        const TArray<ETradeGoodType>& IllegalGoods)
    {
        // TODO: ideally replace this with a data table
        float BaseMultiplier = 1.0;

        // Economy-based bonuses
        if (Economy == EEconomyType::Agrarian)
        {
            if (TradeGood == ETradeGoodType::EssentialGoods || TradeGood == ETradeGoodType::Organics)
                BaseMultiplier *= 1.5;
            else
                BaseMultiplier *= 0.5;
        }
        if (Economy == EEconomyType::Extractive)
        {
            if (TradeGood == ETradeGoodType::CommonMinerals || TradeGood == ETradeGoodType::RareMinerals)
                BaseMultiplier *= 1.6;
            else if (TradeGood == ETradeGoodType::Fuel)
                BaseMultiplier *= 1.3;
            else
                BaseMultiplier *= 0.4;
        }
        if (Economy == EEconomyType::Industrial)
        {
            if (TradeGood == ETradeGoodType::EquipmentParts || TradeGood == ETradeGoodType::ConsumerTech ||
                TradeGood == ETradeGoodType::Microchips || TradeGood == ETradeGoodType::Weapons ||
                TradeGood == ETradeGoodType::Ammunition || TradeGood == ETradeGoodType::RefinedMinerals)
                BaseMultiplier *= 2.0;

            if (Race == ERaceType::Faeyan &&
               (TradeGood == ETradeGoodType::Microchips || TradeGood == ETradeGoodType::ConsumerTech || TradeGood == ETradeGoodType::EquipmentParts))
                BaseMultiplier *= 1.2;
        }
        if (Economy == EEconomyType::Mixed)
        {
            if (TradeGood == ETradeGoodType::CommonMinerals || TradeGood == ETradeGoodType::RareMinerals)
                BaseMultiplier *= 1.2;

            if (TradeGood == ETradeGoodType::LuxuryGoods || TradeGood == ETradeGoodType::Synthetics ||
                TradeGood == ETradeGoodType::ViceGoods || TradeGood == ETradeGoodType::Medicine ||
                TradeGood == ETradeGoodType::Fuel || TradeGood == ETradeGoodType::Narcotics)
                BaseMultiplier *= 1.6;

            if (Race == ERaceType::Human && TradeGood == ETradeGoodType::ViceGoods)
                BaseMultiplier *= 1.4;

            if (Race == ERaceType::Gaalian && TradeGood == ETradeGoodType::LuxuryGoods)
                BaseMultiplier *= 1.2;
        }

        // General Race-based bonuses
        if (Race == ERaceType::Peleng && TradeGood == ETradeGoodType::Narcotics)
            BaseMultiplier *= 1.5;

        if (Race == ERaceType::Human && TradeGood == ETradeGoodType::Medicine)
            BaseMultiplier *= 1.2;

        if (Race == ERaceType::Maloq)
        {
            if (TradeGood == ETradeGoodType::EssentialGoods) BaseMultiplier *= 2.0;
            if (TradeGood == ETradeGoodType::Weapons || TradeGood == ETradeGoodType::Ammunition) BaseMultiplier *= 1.2;
            if (TradeGood == ETradeGoodType::ConsumerTech) BaseMultiplier *= 0.7;
        }

        if (Race == ERaceType::Gaalian)
        {
            if (TradeGood == ETradeGoodType::Synthetics) BaseMultiplier *= 1.2;
            if (TradeGood == ETradeGoodType::LuxuryGoods) BaseMultiplier *= 1.2;
        }

        if (TradeGood == ETradeGoodType::ConsumerTech && PoliticalSystem == EPoliticalSystem::Theocracy)
        {
            if (Race != ERaceType::Faeyan) BaseMultiplier *= 0.0;
            else BaseMultiplier *= 0.5;
        }

        if (TradeGood == ETradeGoodType::Weapons || TradeGood == ETradeGoodType::Ammunition)
            BaseMultiplier *= (PoliticalSystem == EPoliticalSystem::Dictatorship) ? 1.2 : 1.0;

        if (IllegalGoods.Contains(TradeGood))
        {
            if (PoliticalSystem == EPoliticalSystem::Dictatorship)
                BaseMultiplier *= 0.1;  // strict crackdown
            else
                BaseMultiplier *= 0.5;
        }

        // higher supply ratio -> less production
        // depending on the multiplier calculated, this will balance out with the consumption amount if left running.
        float SupplyFactor = Math::GetMappedRangeValueClamped(FVector2D(0.0, 2.0), FVector2D(2.0, 0.5), SupplyRatio);
        return BaseMultiplier * SupplyFactor * SupplyChainMultiplier;
    }

    UFUNCTION(BlueprintPure)
    bool IsLegal(ETradeGoodType TradeGood, ERaceType Race, EPoliticalSystem PoliticalSystem)
    {
        // Absolute legality: Peleng race or Anarchy political system
        if (Race == ERaceType::Peleng || PoliticalSystem == EPoliticalSystem::Anarchy)
            return true;

        if (TradeGood == ETradeGoodType::LuxuryGoods)
        {
            if (Race == ERaceType::Maloq && PoliticalSystem != EPoliticalSystem::Monarchy)
                return false;
        }

        if (TradeGood == ETradeGoodType::ViceGoods)
        {
            if (Race == ERaceType::Maloq || Race == ERaceType::Gaalian)
                return false;
            if (Race == ERaceType::Faeyan && (PoliticalSystem == EPoliticalSystem::Monarchy || PoliticalSystem == EPoliticalSystem::Dictatorship))
                return false;
        }

        if (TradeGood == ETradeGoodType::ConsumerTech)
        {
            if (Race != ERaceType::Faeyan && PoliticalSystem == EPoliticalSystem::Theocracy)
                return false;
        }

        if (TradeGood == ETradeGoodType::Weapons || TradeGood == ETradeGoodType::Ammunition)
        {
            if ((Race == ERaceType::Faeyan || Race == ERaceType::Gaalian) && PoliticalSystem != EPoliticalSystem::Dictatorship)
                return false;
            if (Race == ERaceType::Human && PoliticalSystem == EPoliticalSystem::Democracy)
                return false;
        }

        if (TradeGood == ETradeGoodType::Narcotics)
        {
            if (Race == ERaceType::Human && PoliticalSystem == EPoliticalSystem::Monarchy)
                return true;
            if (Race == ERaceType::Faeyan && PoliticalSystem == EPoliticalSystem::Dictatorship)
                return true;

            return false;
        }

        // interesting combinations:
        // Maloq Theocracy -> 4 bans: Luxury Goods, Vice Goods, Tech Goods, Narcotics banned
        // Faeyan Dictatorship -> 1 ban: Vice Goods
        // Human Monarchy - Everything legal
        // Combinations that shouldn't exist: Maloq Democracy and Gaalian Anarchy

        return true;
    }

    UFUNCTION(BlueprintPure)
    bool IsEssential(ETradeGoodType TradeGood, ERaceType Race)
    {
        TArray<ETradeGoodType> Goods = GetEssentialGoods(Race);
        return Goods.Contains(TradeGood);
    }

    UFUNCTION(BlueprintPure)
    EEconomySituation GetSituation(float SupplyRatio=1.0)
    {
        if      (SupplyRatio < MajorDeficitSupplyRatio)
            return EEconomySituation::MajorDeficit;
        else if (SupplyRatio < DeficitSupplyRatio)
            return EEconomySituation::Deficit;
        else if (SupplyRatio < SurplusSupplyRatio)
            return EEconomySituation::Balanced;
        else if (SupplyRatio < MajorSurplusSupplyRatio)
            return EEconomySituation::Surplus;
        else
            return EEconomySituation::MajorSurplus;
    }

    UFUNCTION()
    float GetBracketedQuantity(EEconomySituation Situation, float Equilibrium=1.0)
    {
        switch (Situation)
        {
            case EEconomySituation::Balanced:
                return Equilibrium;
            case EEconomySituation::Deficit:
                return Equilibrium * DeficitSupplyRatio;
            case EEconomySituation::MajorDeficit:
                return Equilibrium * MajorDeficitSupplyRatio;
            case EEconomySituation::Surplus:
                return Equilibrium * SurplusSupplyRatio;
            case EEconomySituation::MajorSurplus:
                return Equilibrium * MajorSurplusSupplyRatio;
        }
    }

        // Producers spawned per trade good, before politics / development modifiers.
    //                                                                  Base |  Theo Anar Mona Dict Olig Demo |  Extr Indu Mixd Agra
    FProducerSpawnRules GetProducerSpawnRules(ETradeGoodType TradeGood)
    {
        switch (TradeGood)
        {
            case ETradeGoodType::EssentialGoods:  return FProducerSpawnRules(4,   0,  0, -1, -1,  2,  1,   0,  0,  0,  3);
            case ETradeGoodType::Medicine:        return FProducerSpawnRules(3,  -2,  0, -1,  0,  1,  2,   0,  0,  1,  0);
            case ETradeGoodType::Organics:        return FProducerSpawnRules(3,   1,  0, -1, -1,  1,  1,   0, -1,  0,  2);
            case ETradeGoodType::Synthetics:      return FProducerSpawnRules(3,   0,  0, -1,  2,  1,  0,   0,  1,  2,  0);
            case ETradeGoodType::CommonMinerals:  return FProducerSpawnRules(4,   1,  0,  1,  2,  0, -1,   0, -1,  0,  1);
            case ETradeGoodType::RareMinerals:    return FProducerSpawnRules(2,   1,  0, -1,  0,  1,  1,   0,  1,  0, -1);
            case ETradeGoodType::RefinedMinerals: return FProducerSpawnRules(3,   1,  0, -1, -1,  1,  2,   0,  1,  0,  0);
            case ETradeGoodType::ViceGoods:       return FProducerSpawnRules(2,  -2,  1, -1, -1,  0,  0,   0,  0,  1,  0);
            case ETradeGoodType::Microchips:      return FProducerSpawnRules(2, -10,  0,  0, -1,  1,  2,   0,  2,  0, -1);
            case ETradeGoodType::ConsumerTech:    return FProducerSpawnRules(2, -10,  0,  0, -1,  1,  2,   0,  2,  0, -1);
            case ETradeGoodType::HeavyMachinery:  return FProducerSpawnRules(1, -10, -3,  0,  0,  1,  1,   0,  1, -1, -3);
            case ETradeGoodType::LuxuryGoods:     return FProducerSpawnRules(2,   2,  1,  0,  0,  1,  1,   0,  1,  2, -1);
            case ETradeGoodType::Fuel:            return FProducerSpawnRules(4,  -1,  0, -1, -1,  1,  1,   0,  0,  1,  0);
            case ETradeGoodType::Ammunition:      return FProducerSpawnRules(3,  -1,  1,  1,  1,  1,  0,   0,  1,  0,  0);
            case ETradeGoodType::EquipmentParts:  return FProducerSpawnRules(2, -10,  0,  0, -1,  1,  1,   0,  2,  0, -1);
            case ETradeGoodType::Weapons:         return FProducerSpawnRules(3,  -1,  1,  1,  1,  0,  0,   0,  1,  0,  0);
            case ETradeGoodType::Narcotics:       return FProducerSpawnRules(1,  -1,  2, -1, -2, -1,  0,   0, -1,  0,  1);
            default:                              return FProducerSpawnRules(); // NoType / anything unlisted: spawns none
        }
    }

    int GetProducerPoliticsSpawnBonus(const FProducerSpawnRules& Rules, EPoliticalSystem PoliticalSystem)
    {
        switch (PoliticalSystem)
        {
            case EPoliticalSystem::Theocracy:    return Rules.PoliticsTheocracy;
            case EPoliticalSystem::Anarchy:      return Rules.PoliticsAnarchy;
            case EPoliticalSystem::Monarchy:     return Rules.PoliticsMonarchy;
            case EPoliticalSystem::Dictatorship: return Rules.PoliticsDictatorship;
            case EPoliticalSystem::Oligarchy:    return Rules.PoliticsOligarchy;
            case EPoliticalSystem::Democracy:    return Rules.PoliticsDemocracy;
            default:                             return 0;
        }
    }

    int GetProducerDevelopmentSpawnBonus(const FProducerSpawnRules& Rules, EEconomyType EconomyType)
    {
        switch (EconomyType)
        {
            case EEconomyType::Extractive: return Rules.DevelopmentExtractive;
            case EEconomyType::Industrial: return Rules.DevelopmentIndustrial;
            case EEconomyType::Mixed:      return Rules.DevelopmentMixed;
            case EEconomyType::Agrarian:   return Rules.DevelopmentAgrarian;
            case EEconomyType::Resort:     return 0; // Add a field on FProducerSpawnRules if Resort has one
            default:                       return 0;
        }
    }
}
