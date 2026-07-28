//Used inside the target's state function
struct FDamageCalculationInput
{
    UPROPERTY() float UnmitigatedDamage = 0.0;
    UPROPERTY() float ShieldBypass              = 0.0; // 0-1, from FWeaponProperties
    UPROPERTY() float CurrentShieldPoints       = 0.0;
    UPROPERTY() bool  bShieldsActive            = true;
    UPROPERTY() float ShieldDamageBlock         = 0.0; // from FShieldGeneratorProperties
    UPROPERTY() float ShipDamageResistance      = 1.0; // armor
    UPROPERTY() float TypeSpecificResistance    = 1.0; // Kinetic/Energetic/Explosive, picked by caller
    UPROPERTY() float GlobalDamageModifier      = 1.0; // from attacker's GlobalDamage.* bonuses
    UPROPERTY() bool  bIsInvulnerable           = false;
};

struct FDamageCalculationOutput
{
    UPROPERTY() float ShieldDamage = 0.0;
    UPROPERTY() float HullDamage = 0.0;
};


namespace GameLogic
{
    const float StatScale = 6.0;
    const float GShipEnergyBuildupPerDamage = 0.5;
    const float GShipEnergyBuildupPerShieldDamage = 0.5;
    const float GShipEnergyBuildupPerHullDamage = 0.1;
    const float GHullReliabilityThreshold_Major = 25;
    const float GHullReliabilityThreshold_Critical = 10;
    const float GHullReliabilitySpeedMult_Major = 0.75;
    const float GHullReliabilitySpeedMult_Critical = 0.3;

    //Pickups
    const float SnapCollectRadius = 30.0; //When an item's distance is < this, instantly pick up
    const float ContestHysteresis = 1.5;  //How much bigger an opposing actor's score need to be to claim an item.
    const float ClusterSplitGap = 140.0;  // If the empty space between two items is larger than this, split the stop.

    

    // ── Accuracy/Evasion-biased damage roll ───────────────────────────────────────
    // Ported directly from the GAS prototype's RangeIncrement/RangeSize/Lerp
    // block. StatScale = 6 to match this system's 0-6 Accuracy/Evasion clamp.
    float RollWeaponDamage(float MinDamage, float MaxDamage, float Accuracy, float Evasion)
    {
        float NewMinDamage = Math::Max(MinDamage, 0);
        float NewMaxDamage = Math::Max(MaxDamage, 0);

        if (NewMinDamage == NewMaxDamage) return MaxDamage;

        float RangeIncrement = Accuracy - Evasion; // -6 to 6
        float RangeSize      = StatScale - Math::Abs(RangeIncrement);

        float MinValue = (RangeIncrement + StatScale - RangeSize) / (StatScale * 2);
        float MaxValue = (RangeIncrement + StatScale + RangeSize) / (StatScale * 2);

        float RandomAlpha = Math::RandRange(MinValue, MaxValue);

        return (NewMinDamage < NewMaxDamage)
            ? Math::Lerp(NewMinDamage, NewMaxDamage, RandomAlpha)
            : Math::Lerp(NewMaxDamage, NewMinDamage, RandomAlpha);
    }

    FDamageCalculationOutput CalculateDamage(const FDamageCalculationInput& Input)
    {
        FDamageCalculationOutput Output;

        if (Input.bIsInvulnerable) return Output; // both stay 0

        float HealthDamage = Input.UnmitigatedDamage;
        float ShieldDamage = Input.UnmitigatedDamage;

        if (Input.ShieldBypass != 1.0)
        {
            if (Input.ShieldBypass > 0.0)
            {
                ShieldDamage = Input.UnmitigatedDamage * (1 - Input.ShieldBypass);
                HealthDamage = Input.UnmitigatedDamage * Input.ShieldBypass;

                if (ShieldDamage > Input.CurrentShieldPoints)
                {
                    // Don't waste damage at low shields — overflow carries to health,
                    const float ShieldDifference = ShieldDamage - Input.CurrentShieldPoints;
                    ShieldDamage = Input.CurrentShieldPoints;
                    HealthDamage += ShieldDifference;
                }
            }

            if (Input.CurrentShieldPoints > 0 && Input.bShieldsActive)
            {
                ShieldDamage = Math::Max(0, ShieldDamage);

                // Re-check overflow now that the block reduced ShieldDamage —
                // the blocked portion never carries to health, it's just negated.
                if (ShieldDamage > Input.CurrentShieldPoints)
                {
                    const float ShieldDifference = ShieldDamage - Input.CurrentShieldPoints;
                    ShieldDamage = Input.CurrentShieldPoints;
                    HealthDamage += ShieldDifference;
                }

                Output.ShieldDamage = Math::RoundToFloat(ShieldDamage);

                if (Input.ShieldBypass == 0)
                {
                    // Full bypass-free hit fully absorbed by shields (modulo the
                    // block reduction above) — no health damage this hit, same
                    // early-return shape as the prototype.
                    return Output;
                }
            }
            else
            {
                HealthDamage = Input.UnmitigatedDamage;
            }
        }

        const float MitigatedDamage = Math::RoundToFloat(
            Math::Max(
                (HealthDamage * Input.GlobalDamageModifier * Input.ShipDamageResistance * Input.TypeSpecificResistance) - Input.ShieldDamageBlock,
                1));

        Output.HullDamage = MitigatedDamage;
        return Output;
    }

    // ── Reliability speed multiplier (hull only) ──────────────────────────────────

    float GetReliabilitySpeedMultiplier(float Reliability)
    {
        if (Reliability < GHullReliabilityThreshold_Critical) return GHullReliabilitySpeedMult_Critical; // <10%
        if (Reliability < GHullReliabilityThreshold_Major)    return GHullReliabilitySpeedMult_Major;     // <25%
        return 1; // healthy — no penalty
    }

    // ── Target energy buildup ─────────────────────────────────────────────────────

    float CalculateTargetEnergyBuildup(
        float HullDamage, float ShieldDamage, float WeaponTargetEnergyBuildupMultiplier)
    {
        return HullDamage * GShipEnergyBuildupPerHullDamage * WeaponTargetEnergyBuildupMultiplier + 
            ShieldDamage * GShipEnergyBuildupPerHullDamage * WeaponTargetEnergyBuildupMultiplier;
    }

    float GetShipSpeed(float ShipMaxSpeed, float ShipMass, float SlowdownMultiplier, float ShipReliability, 
        float AccelerationMultipliers, float FlatBonuses, bool bIsAfterburnerActive)
    {
        float k_weight = Math::GetMappedRangeValueClamped(FVector2D(750.0, 2500.0), FVector2D(1.0, 0.333), ShipMass);
        float k_slowdown = Math::Clamp(SlowdownMultiplier, 0.5f, 1.0);
        float k_broken = Math::Clamp(ShipReliability, 0.3f,1.0);

        // SpeedKoef = e^(-4thRoot( Sum( ln^4(k_i) ) ))
        float SumLn4 = Math::Pow(Math::Loge(k_weight), 4.0);
        SumLn4 += Math::Pow(Math::Loge(k_slowdown), 4.0);
        SumLn4 += Math::Pow(Math::Loge(k_broken), 4.0);

        float SpeedKoef = Math::Exp(-Math::Pow(SumLn4, 0.25));
        
        //Flat bonuses before scaling
        float RawSpeed = (ShipMaxSpeed * SpeedKoef * AccelerationMultipliers) + FlatBonuses;

        if (bIsAfterburnerActive)
        {
            RawSpeed *= 2.0;
        }

        float FinalSpeed = RawSpeed;

        //The hardcoded speed values represent the brackets at which a calculated speed 
        //might fall into so that the speed is never reduced at any point.
        if (RawSpeed < 200.0)
        {
            FinalSpeed = 200.0 - (200.0 - RawSpeed) * 0.2;
        }
        else if (RawSpeed > 2000.0)
        {
            FinalSpeed = 1600.0 + (RawSpeed - 2000.0) * 0.2;
        }
        else if (RawSpeed > 1500.0)
        {
            FinalSpeed = 1350.0 + (RawSpeed - 1500.0) * 0.5;
        }
        else if (RawSpeed > 1000.0)
        {
            FinalSpeed = 1000.0 + (RawSpeed - 1000.0) * 0.7;
        }

        return FinalSpeed;
    }

    // Folds every modifier matching StatTag onto BaseValue.
    //   Additive        -> summed first
    //   Multiplicative   -> applied as (1 + Value) factors on top of the additive sum
    //   Override         -> if any Override is present it wins outright, ignoring
    //                        every other modifier (matches EStatType's own comment)
    float ApplyModifiers(float BaseValue, FGameplayTag StatTag, const TArray<FStatModifier>& Modifiers)
    {
        float AdditiveSum = 0.0;
        float MultiplicativeFactor = 1.0;
        bool bHasOverride = false;
        float OverrideValue = 0.0;

        for (const auto& Modifier : Modifiers)
        {
            if (Modifier.StatTag != StatTag)
                continue;

            switch (Modifier.Type)
            {
                case EStatType::Additive:
                    AdditiveSum += Modifier.Value;
                    break;
                case EStatType::Multiplicative:
                    MultiplicativeFactor *= (1.0 + Modifier.Value);
                    break;
                case EStatType::Override:
                    bHasOverride = true;
                    OverrideValue = Modifier.Value;
                    break;
            }
        }

        if (bHasOverride)
            return OverrideValue;

        return BaseValue * MultiplicativeFactor + AdditiveSum;
    }

    float GetHullMass(float TotalCarryCapacity, int TechLevel)
    {
        return Math::RoundToFloat(TotalCarryCapacity * (0.6 + 0.03 * (TechLevel - 1)));
    }

}