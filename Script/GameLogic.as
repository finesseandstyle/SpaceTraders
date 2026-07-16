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
        float k_weight = Math::GetMappedRangeValueClamped(FVector2D(750.0f, 2500.0f), FVector2D(1.0f, 0.333f), ShipMass);
        float k_slowdown = Math::Clamp(SlowdownMultiplier, 0.5f, 1.0f);
        float k_broken = Math::Clamp(ShipReliability, 0.3f,1.0f);

        // SpeedKoef = e^(-4thRoot( Sum( ln^4(k_i) ) ))
        float SumLn4 = Math::Pow(Math::Loge(k_weight), 4.0f);
        SumLn4 += Math::Pow(Math::Loge(k_slowdown), 4.0f);
        SumLn4 += Math::Pow(Math::Loge(k_broken), 4.0f);

        float SpeedKoef = Math::Exp(-Math::Pow(SumLn4, 0.25f));
        
        //Flat bonuses before scaling
        float RawSpeed = (ShipMaxSpeed * SpeedKoef * AccelerationMultipliers) + FlatBonuses;

        if (bIsAfterburnerActive)
        {
            RawSpeed *= 2.0f;
        }

        float FinalSpeed = RawSpeed;

        //The hardcoded speed values represent the brackets at which a calculated speed 
        //might fall into so that the speed is never reduced at any point.
        if (RawSpeed < 200.0f)
        {
            FinalSpeed = 200.0f - (200.0f - RawSpeed) * 0.2f;
        }
        else if (RawSpeed > 2000.0f)
        {
            FinalSpeed = 1600.0f + (RawSpeed - 2000.0f) * 0.2f;
        }
        else if (RawSpeed > 1500.0f)
        {
            FinalSpeed = 1350.0f + (RawSpeed - 1500.0f) * 0.5f;
        }
        else if (RawSpeed > 1000.0f)
        {
            FinalSpeed = 1000.0f + (RawSpeed - 1000.0f) * 0.7f;
        }

        return FinalSpeed;
    }

}