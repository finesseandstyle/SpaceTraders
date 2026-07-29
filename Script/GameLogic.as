//Used inside the target's state function
struct FDamageCalculationInput
{
    UPROPERTY() float SourceUnmitigatedDamage = 0.0;
    UPROPERTY() float SourceShieldBypass              = 0.0; // 0-1, from FWeaponProperties
    UPROPERTY() float TargetCurrentShields       = 0.0;
    UPROPERTY() bool  bTargetHasShieldsActive            = true;
    UPROPERTY() float TargetShieldDamageBlock         = 0.0; // from FShieldGeneratorProperties
    UPROPERTY() float TargetShipDamageResistance      = 1.0; // armor
    UPROPERTY() float TargetTypeSpecificResistance    = 1.0; // Kinetic/Energetic/Explosive, picked by caller
    UPROPERTY() float SourceGlobalDamageModifier      = 1.0; // from attacker's GlobalDamage.* bonuses
    UPROPERTY() bool  bTargetIsInvulnerable           = false;
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

    const float MinMass = 750;
    const float MaxMass = 2500;

    //Pickups
    const float SnapCollectRadius = 20.0; //When an item's distance is < this, instantly pick up
    const float ContestHysteresis = 1.5;  //How much bigger an opposing actor's score need to be to claim an item.
    const float ClusterSplitGap = 150.0;  // If the empty space between two items is larger than this, split the stop.

    

    // ── Accuracy/Evasion-biased damage roll ───────────────────────────────────────
    // Ported directly from the GAS prototype's RangeIncrement/RangeSize/Lerp
    // block. StatScale = 6 to match this system's 0-6 Accuracy/Evasion clamp.
    float RollWeaponDamage(float MinDamage, float MaxDamage, float Accuracy, float Evasion)
    {
        float NewMinDamage = Math::Max(MinDamage, 0);
        float NewMaxDamage = Math::Max(MaxDamage, 0);

        //Special case for weapons with a fixed damage value
        if (NewMinDamage == 0) return MaxDamage;

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

        if (Input.bTargetIsInvulnerable) 
            return Output;

        float RawHealthDamage = Input.SourceUnmitigatedDamage;
        float RawShieldDamage = 0.0;

        // Only process shield damage if shields are active and have health remaining
        if (Input.bTargetHasShieldsActive && Input.TargetCurrentShields > 0.0)
        {
            // Split damage between shields and health based on bypass (0.0 = 100% to shield, 1.0 = 100% to health)
            RawShieldDamage = Input.SourceUnmitigatedDamage * (1.0 - Input.SourceShieldBypass);
            RawHealthDamage = Input.SourceUnmitigatedDamage * Input.SourceShieldBypass;

            // Apply Shield Damage Block flat reduction before checking shield depletion/overflow
            RawShieldDamage = Math::Max(0.0, RawShieldDamage - Input.TargetShieldDamageBlock);

            // Handle shield overflow: excess damage beyond current shield points spills over to health
            if (RawShieldDamage > Input.TargetCurrentShields)
            {
                float OverflowDamage = RawShieldDamage - Input.TargetCurrentShields;
                RawShieldDamage = Input.TargetCurrentShields;
                RawHealthDamage += OverflowDamage;
            }

            Output.ShieldDamage = Math::RoundToFloat(RawShieldDamage);

            // Fast-path: If full hit went to shields (0% bypass) and shields didn't break, no health damage occurs
            if (Input.SourceShieldBypass <= 0.0 && RawHealthDamage <= 0.0)
            {
                return Output;
            }
        }

        // Apply resistances, global modifiers, and armor block to health portion
        float FinalHullDamage = (RawHealthDamage * Input.SourceGlobalDamageModifier 
                                                * Input.TargetShipDamageResistance 
                                                * Input.TargetTypeSpecificResistance);

        // Ensure a successful hit that bypasses or breaks shields does at least 1 point of damage
        Output.HullDamage = Math::RoundToFloat(Math::Max(FinalHullDamage, 1.0));

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
            ShieldDamage * GShipEnergyBuildupPerShieldDamage * WeaponTargetEnergyBuildupMultiplier;
    }

    // ── Ship speed (Space Rangers HD derived) ──────────────────────────────────
    /**
     * ShipMaxSpeed - Includes Base Speed + potential Upgrades and Micromodule effects.
     *                The hull item's own FStatAttribute for Speed's Value is this.
     * ShipMass - Calculated from ShipState's CurrentMass (GetTotalShipMass())
     * SlowdownMultiplier - OnHitEffects that reduce our SlowdownMultiplier to a min of 0.5
     * ShipReliability - Replaces SRHD's Engine broken check, either 1.0, 0.75 or 0.3 depending on threshold
     * MultiplierBonuses - Artifacts like Psi Matter Accelerator and Stimulant Gaalian Alacrity that grant % change
     * FlatBonuses - Artifacts like Soplanator and Acrine (Global) that give flat bonuses
     */
    float GetShipSpeed(float ShipMaxSpeed, float ShipMass, float SlowdownMultiplier, float ShipReliability, 
        float MultiplierBonuses, float FlatBonuses)
    {
        float k_weight = Math::GetMappedRangeValueClamped(FVector2D(MinMass, MaxMass), FVector2D(1.0, 0.333), ShipMass);
        float k_slowdown = Math::Clamp(SlowdownMultiplier, 0.5f, 1.0);
        float k_broken = Math::Clamp(ShipReliability, 0.3f,1.0);

        // SpeedKoef = e^(-4thRoot( Sum( ln^4(k_i) ) ))
        float SumLn4 = Math::Pow(Math::Loge(k_weight), 4.0);
        SumLn4 += Math::Pow(Math::Loge(k_slowdown), 4.0);
        SumLn4 += Math::Pow(Math::Loge(k_broken), 4.0);

        float SpeedKoef = Math::Exp(-Math::Pow(SumLn4, 0.25));

        //Flat bonuses before scaling
        float RawSpeed = (ShipMaxSpeed * SpeedKoef * MultiplierBonuses) + FlatBonuses;

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
    //   Multiplicative -> applied to BaseValue first, as a (1 + Value) factor
    //   Additive        -> summed and added on top of the scaled result
    //   Override        -> if any Override is present it wins outright, ignoring
    //                       every other modifier (matches EStatType's own comment)
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

        return (BaseValue * MultiplicativeFactor) + AdditiveSum;
    }

    // Like ApplyModifiers, but folds modifiers from SEVERAL stat tags onto
    // one shared BaseValue instead of just one. Needed for things like a
    // weapon's effective MaxDamage: "DamageGlobal" and "DamageKinetic" are
    // two separate tags that both need to scale/add against *that weapon's*
    // own MaxDamage - they can't be pre-resolved into a single ship-wide
    // number the way GetShipStat() resolves MaxShieldPoints or RadarRange,
    // because a Multiplicative modifier on either tag only means something
    // relative to the specific base it's meant to scale.
    //
    // All Multiplicative modifiers across every tag in the group combine
    // into one factor applied to BaseValue first; all Additive modifiers
    // across every tag combine into one flat sum added on top. Override is
    // not handled here - it's not generally meaningful for a multi-tag
    // bonus group and would need bespoke handling if a use case comes up.
    float ApplyModifierGroup(float BaseValue, const TArray<FGameplayTag>& StatTags, const TArray<FStatModifier>& Modifiers)
    {
        float AdditiveSum = 0.0;
        float MultiplicativeFactor = 1.0;

        for (const auto& Modifier : Modifiers)
        {
            if (!StatTags.Contains(Modifier.StatTag))
                continue;

            if (Modifier.Type == EStatType::Multiplicative)
                MultiplicativeFactor *= (1.0 + Modifier.Value);
            else if (Modifier.Type == EStatType::Additive)
                AdditiveSum += Modifier.Value;
        }

        return (BaseValue * MultiplicativeFactor) + AdditiveSum;
    }

    // Same modifier-scanning logic as above, but returns the multiplicative
    // factor and additive sum separately instead of folding them onto a base
    // value. Needed wherever a formula combines them with other terms first
    // rather than just adding them to one number - e.g. GetShipSpeed, where
    // MultiplierBonuses multiplies against SpeedKoef and FlatBonuses is only
    // added at the very end.
    struct FModifierComponents
    {
        float MultiplicativeFactor = 1.0;
        float AdditiveSum = 0.0;
    }

    FModifierComponents GetModifierComponents(FGameplayTag StatTag, const TArray<FStatModifier>& Modifiers)
    {
        FModifierComponents Result;

        for (const auto& Modifier : Modifiers)
        {
            if (Modifier.StatTag != StatTag)
                continue;

            if (Modifier.Type == EStatType::Multiplicative)
                Result.MultiplicativeFactor *= (1.0 + Modifier.Value);
            else if (Modifier.Type == EStatType::Additive)
                Result.AdditiveSum += Modifier.Value;
        }

        return Result;
    }
}