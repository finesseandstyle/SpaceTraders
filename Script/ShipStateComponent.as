// ============================================================================
// ShipStateComponent.as
//
// Attached to any ship or space station actor. Owns equipment, cargo,
// the aggregated ship-wide stat cache, and the three stats that change
// during turn execution: Hull Points, Shield Points, Heat.
//
// Assumptions about the surrounding project (adjust if these don't match):
//   - RollWeaponDamage / CalculateDamage / GetReliabilitySpeedMultiplier /
//     CalculateTargetEnergyBuildup / FDamageCalculationInput / Output are
//     declared globally in your existing damage-math file and are visible
//     here without an explicit import (Angelscript module-wide resolution).
//   - GameplayTags::TagName is how native gameplay tags are exposed to
//     script, matching the convention already used in ItemSystem.as
//     (GameplayTags::StatSource_Upgrade, etc).
//   - Slot tags such as SpaceShip_Equipment_Weapon_1 are real dot-hierarchy
//     children of SpaceShip_Equipment_Weapon (i.e. the tag's actual name is
//     "SpaceShip.Equipment.Weapon.Weapon_1"), so FGameplayTag::MatchesTag()
//     can be used for slot/item-type compatibility checks. If your tags are
//     flat instead, swap IsItemCompatibleWithSlot() for an explicit
//     slot -> accepted-ItemType lookup table.
//   - Print(FString) is your project's quick debug-log function; swap it in
//     RunSelfTest() for whatever you actually use.
// ============================================================================

event void FShipHullDestroyed(UShipStateComponent Ship);
event void FShipOverheated(UShipStateComponent Ship);
event void FShipShieldsDepleted(UShipStateComponent Ship);

class UShipStateComponent : UActorComponent
{
    // ------------------------------------------------------------------
    // Equipment & inventory
    // ------------------------------------------------------------------

    // Every slot this ship currently has, keyed by its gameplay tag
    // (SpaceShip_Equipment_Weapon_1, SpaceShip_Equipment_ShieldGenerator, ...).
    UPROPERTY() FGameItem Hull = FGameItem();
    UPROPERTY() TMap<FGameplayTag, FGameItem> EquipmentSlots;

    // General cargo hold: trade goods, spare unequipped gear, etc.
    UPROPERTY() TArray<FGameItem> CargoHold;

    // ------------------------------------------------------------------
    // Ship-wide stat cache (Level 2 of the two-tier smart recalculation -
    // see RecalculateShipStats() below for Level 1).
    // ------------------------------------------------------------------

    // Designer-set baselines not tied to any single item - Core Character
    // Stats like Accuracy/Evasion typically start here rather than at 0.
    UPROPERTY() TArray<FStatAttribute> CharacterStats;

    // Ship-wide modifiers that don't belong to any one item: StatSource_Acrine
    // (global race bonuses) and StatSource_ActiveEffect (stimulants etc).
    UPROPERTY() TArray<FStatModifier> GlobalModifiers;

    // Transient - not saved, rebuilt from the above whenever it's stale.
    private TMap<FGameplayTag, float> CachedShipStats;
    private bool bStatsDirty = true;

    // ------------------------------------------------------------------
    // Turn-mutable combat state
    // ------------------------------------------------------------------

    // Hull Points are NOT duplicated here - they live on the equipped hull's
    // CurrentDurability/MaxDurability. See GetCurrentHullPoints/GetMaxHullPoints.

    UPROPERTY() float CurrentShieldPoints = 0.0;
    UPROPERTY() bool bShieldsActive = true; // toggled once per turn by the player, like a stance
    UPROPERTY() int32 TurnsSinceShieldDamage = 0;
    UPROPERTY() int32 ShieldRegenDelayTurns = 2; // n turns with no shield damage before regen resumes
    UPROPERTY() float ShieldRegenPercentPerTurn = 0.1; // fraction of max regenerated per turn once active
    UPROPERTY() float CurrentHeat = 0.0;
    UPROPERTY() bool bIsOverheated = false;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    UPROPERTY() FShipHullDestroyed OnHullDestroyed;
    UPROPERTY() FShipOverheated OnOverheated;
    UPROPERTY() FShipShieldsDepleted OnShieldsDepleted;

    // ==================================================================
    // Slot management
    // ==================================================================

    bool IsSlotEmpty(FGameplayTag SlotTag)
    {
        return !EquipmentSlots.Contains(SlotTag);
    }

    FGameItem GetItemInSlot(FGameplayTag SlotTag)
    {
        return EquipmentSlots.Contains(SlotTag) ? EquipmentSlots[SlotTag] : FGameItem();
    }

    // Assumes dot-hierarchy tags - see file header. SlotTag matches if it
    // equals, or is a child of, the item's declared ItemType.
    bool IsItemCompatibleWithSlot(FGameplayTag SlotTag, FGameItem Item)
    {
        if (!Item.IsValid())
            return false;

        return SlotTag.MatchesTag(Item.ItemDefinition.ItemType);
    }

    UFUNCTION()
    bool EquipItem(FGameplayTag SlotTag, FGameItem Item)
    {
        if (!EquipmentSlots.Contains(SlotTag))
            return false; // no hull currently grants this slot

        if (!IsItemCompatibleWithSlot(SlotTag, Item))
            return false;

        UnequipItem(SlotTag); // whatever was there goes back to cargo first

        EquipmentSlots[SlotTag] = Item;

        MarkStatsDirty();
        return true;
    }

    UFUNCTION()
    FGameItem UnequipItem(FGameplayTag SlotTag)
    {
        FGameItem Removed;
        if (EquipmentSlots.Contains(SlotTag))
        {
            Removed = EquipmentSlots[SlotTag];
            EquipmentSlots[SlotTag] = FGameItem();
            CargoHold.Add(Removed);
        }
        MarkStatsDirty();
        return Removed;
    }

    UFUNCTION(BlueprintCallable)
    bool EquipFromCargo(int32 CargoIndex, FGameplayTag SlotTag)
    {
        if (CargoIndex < 0 || CargoIndex >= CargoHold.Num())
            return false;

        FGameItem Item = CargoHold[CargoIndex];
        if (!EquipItem(SlotTag, Item))
            return false;

        CargoHold.RemoveAt(CargoIndex);
        return true;
    }

    // ==================================================================
    // Item instantiation
    // ==================================================================

    // Builds a runtime FGameItem from a template UItemDefinition (a Data
    // Asset), deep-copying its fragments so this instance gets its own
    // mutable durability/reliability/modifiers instead of sharing state
    // with the template or with other instances of the same item.
    UFUNCTION()
    FGameItem InstantiateItem(UItemDefinition Definition, int32 Mass = 1)
    {
        FGameItem NewItem;
        NewItem.ItemDefinition = Definition;
        NewItem.Mass = Mass;

        if (Definition == nullptr)
            return NewItem;

        NewItem.Value = Definition.BasePrice;

        for (const auto TemplateFragment : Definition.Fragments)
        {
            if (TemplateFragment == nullptr)
                continue;

            NewItem.Fragments.Add(InstantiateFragment(TemplateFragment));
        }

        return NewItem;
    }

    // Explicit field copy rather than a generic deep-copy call, so this
    // works regardless of whether your bindings expose DuplicateObject<T>.
    // If they do, DuplicateObject<UItemFragment>(Template, this) is a much
    // shorter drop-in replacement for this whole function.
    private UItemFragment InstantiateFragment(const UItemFragment Template)
    {
        if (Template == nullptr)
            return nullptr;

        UItemFragment NewFragment = Cast<UItemFragment>(NewObject(this, Template.Class));

        UItemEquipment TemplateEquipment = Cast<UItemEquipment>(Template);
        UItemEquipment NewEquipment = Cast<UItemEquipment>(NewFragment);
        if (TemplateEquipment != nullptr && NewEquipment != nullptr)
        {
            NewEquipment.MaxDurability = TemplateEquipment.MaxDurability;
            NewEquipment.CurrentDurability = NewEquipment.MaxDurability.Value;
            NewEquipment.Reliability = TemplateEquipment.Reliability;
            NewEquipment.TechLevel = TemplateEquipment.TechLevel;
            NewEquipment.Stats = TemplateEquipment.Stats;         // TArray value-copy
            NewEquipment.Modifiers = TemplateEquipment.Modifiers; // start with any baked-in modifiers
            NewEquipment.MarkAllStatsDirty(); // force a real first calculation, ignore whatever the template had saved
        }

        return NewFragment;
    }

    // ==================================================================
    // Stat aggregation (Level 2 - see UItemEquipment::RecalculateStats
    // in ItemSystem.as for Level 1)
    // ==================================================================

    void MarkStatsDirty()
    {
        bStatsDirty = true;
    }

    // DefaultValue matters: additive stats (MaxShieldPoints, EnergyCapacity)
    // should default to 0 when absent, but multiplicative ones (resistances)
    // need to default to 1 or missing equipment would zero out all damage.
    float GetShipStat(FGameplayTag StatTag, float DefaultValue = 0.0)
    {
        RecalculateShipStatsIfDirty();
        return CachedShipStats.Contains(StatTag) ? CachedShipStats[StatTag] : DefaultValue;
    }

    private void RecalculateShipStatsIfDirty()
    {
        if (!bStatsDirty)
            return;
        RecalculateShipStats();
        bStatsDirty = false;
    }

    // Full pass, O(equipped items + their stats). Only runs when
    // bStatsDirty is set by an equip/unequip/modifier change - never on a
    // per-tick or per-query basis. Each item's own RecalculateStats() is
    // itself cheap here because of the per-stat bDirty check (Level 1).
    private void RecalculateShipStats()
    {
        CachedShipStats.Empty();

        for (const auto& BaseStat : CharacterStats)
            CachedShipStats.Add(BaseStat.StatTag, BaseStat.BaseValue);

        TArray<FGameplayTag> SlotTags;
        EquipmentSlots.GetKeys(SlotTags);

        for (FGameplayTag SlotTag : SlotTags)
        {
            FGameItem Item = EquipmentSlots[SlotTag];
            if (!Item.IsValid())
                continue;

            UItemEquipment Fragment = Item.GetEquipmentFragment();
            if (Fragment == nullptr)
                continue;

            Fragment.RecalculateStats();

            for (const auto& Stat : Fragment.Stats)
            {
                float Existing = CachedShipStats.Contains(Stat.StatTag) ? CachedShipStats[Stat.StatTag] : 0.0;
                CachedShipStats.Add(Stat.StatTag, Existing + Stat.Value);
            }
        }

        // Ship-wide effects (Acrine, active effects/stimulants) fold on top last.
        TArray<FGameplayTag> AggregatedTags;
        CachedShipStats.GetKeys(AggregatedTags);
        for (FGameplayTag Tag : AggregatedTags)
            CachedShipStats[Tag] = GameLogic::ApplyModifiers(CachedShipStats[Tag], Tag, GlobalModifiers);
    }

    // ------------------------------------------------------------------
    // Modifier management - installing upgrades / socketing micromodules
    // should go through these so dirtiness cascades correctly.
    // ------------------------------------------------------------------

    UFUNCTION()
    bool AddModifierToSlot(FGameplayTag SlotTag, FStatModifier Modifier)
    {
        if (!EquipmentSlots.Contains(SlotTag))
            return false;

        UItemEquipment Fragment = EquipmentSlots[SlotTag].GetEquipmentFragment();
        if (Fragment == nullptr)
            return false;

        Fragment.AddModifier(Modifier);
        MarkStatsDirty(); // this item feeds the ship cache, so the ship cache is now stale too
        return true;
    }

    UFUNCTION()
    bool RemoveModifiersFromSlot(FGameplayTag SlotTag, FGameplayTag SourceType)
    {
        if (!EquipmentSlots.Contains(SlotTag))
            return false;

        UItemEquipment Fragment = EquipmentSlots[SlotTag].GetEquipmentFragment();
        if (Fragment == nullptr)
            return false;

        Fragment.RemoveModifiersFromSource(SourceType);
        MarkStatsDirty();
        return true;
    }

    UFUNCTION()
    void AddGlobalModifier(FStatModifier Modifier)
    {
        GlobalModifiers.Add(Modifier);
        MarkStatsDirty();
    }

    UFUNCTION()
    void RemoveGlobalModifiersFromSource(FGameplayTag SourceType)
    {
        for (int32 i = GlobalModifiers.Num() - 1; i >= 0; i--)
        {
            if (GlobalModifiers[i].SourceType == SourceType)
                GlobalModifiers.RemoveAt(i);
        }
        MarkStatsDirty();
    }

    private UItemHull GetHullFragment()
    {
        return Cast<UItemHull>(Hull.GetEquipmentFragment());
    }

    // ==================================================================
    // Mass
    // ==================================================================

    // Sum of every equipped item's mass (via FGameItem::GetItemMass) plus
    // everything in the cargo hold, except the hull(s), which use
    // UItemHull::GetHullMass() instead.
    UFUNCTION(BlueprintPure)
    float GetTotalShipMass()
    {
        float TotalMass = 0.0;

        TArray<FGameplayTag> SlotTags;
        EquipmentSlots.GetKeys(SlotTags);

        UItemHull HullFragment = GetHullFragment();
        TotalMass += HullFragment.GetHullMass();

        for (FGameplayTag SlotTag : SlotTags)
        {
            FGameItem Item = EquipmentSlots[SlotTag];
            if (!Item.IsValid())
                continue;


            TotalMass += Item.GetItemMass();
        }

        for (const auto& CargoItem : CargoHold)
            TotalMass += CargoItem.GetItemMass();

        return TotalMass;
    }

    // ==================================================================
    // Hull Points (mirrors the equipped hull's Current/MaxDurability -
    // no separate float duplicated here)
    // ==================================================================

    UFUNCTION(BlueprintPure)
    float GetCurrentHullPoints()
    {
        UItemHull HullFragment = GetHullFragment();
        return HullFragment != nullptr ? HullFragment.CurrentDurability : 0.0;
    }

    float GetMaxHullPoints()
    {
        UItemHull HullFragment = GetHullFragment();
        return HullFragment != nullptr ? HullFragment.MaxDurability.Value : 0.0;
    }

    private void ApplyHullDamage(float HullDamage)
    {
        UItemHull HullFragment = GetHullFragment();
        if (HullFragment == nullptr)
            return; // no hull, nothing to damage against

        HullFragment.CurrentDurability = Math::Max(0.0, HullFragment.CurrentDurability - HullDamage);

        if (HullFragment.CurrentDurability <= 0.0)
            OnHullDestroyed.Broadcast(this);
    }

    // 0-100. Feeds GetReliabilitySpeedMultiplier from the damage-math file
    // (<10% -> critical penalty, <25% -> major penalty).
    float GetHullReliabilityPercent()
    {
        float Max = GetMaxHullPoints();
        if (Max <= 0.0)
            return 100.0;
        return (GetCurrentHullPoints() / Max) * 100.0;
    }

    float GetCurrentSpeedMultiplier()
    {
        return GameLogic::GetReliabilitySpeedMultiplier(GetHullReliabilityPercent());
    }

    // ==================================================================
    // Shield Points
    // ==================================================================

    float GetMaxShieldPoints()
    {
        return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_MaxShieldPoints, 0.0);
    }

    UFUNCTION(BlueprintCallable)
    void SetShieldsActive(bool bActive)
    {
        bShieldsActive = bActive;
    }

    // ==================================================================
    // Heat
    // ==================================================================

    float GetMaxHeat()
    {
        return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_EnergyCapacity, 0.0);
    }

    void AddHeat(float Amount)
    {
        CurrentHeat += Amount;

        float MaxHeat = GetMaxHeat();
        if (MaxHeat > 0.0 && CurrentHeat >= MaxHeat)
        {
            CurrentHeat = MaxHeat;
            if (!bIsOverheated)
            {
                bIsOverheated = true;
                OnOverheated.Broadcast(this);
            }
        }
    }

    // ==================================================================
    // Turn processing
    // ==================================================================

    // Call once per WEGO turn resolution, after orders have been applied.
    UFUNCTION(BlueprintCallable)
    void AdvanceTurn()
    {
        RecalculateShipStatsIfDirty();

        float Dissipation = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_EnergyDissipation, 0.0);
        CurrentHeat = Math::Max(0.0, CurrentHeat - Dissipation);
        if (bIsOverheated && CurrentHeat < GetMaxHeat())
            bIsOverheated = false;

        TurnsSinceShieldDamage++;
        float MaxShields = GetMaxShieldPoints();
        if (bShieldsActive && MaxShields > 0.0 && TurnsSinceShieldDamage >= ShieldRegenDelayTurns)
        {
            CurrentShieldPoints = Math::Min(MaxShields, CurrentShieldPoints + MaxShields * ShieldRegenPercentPerTurn);
        }
    }

    // ==================================================================
    // Damage
    // ==================================================================

    UFUNCTION(BlueprintCallable)
    void ApplyDamage(float UnmitigatedDamage, float ShieldBypass, FGameplayTag DamageType, float GlobalDamageModifier = 1.0)
    {
        FDamageCalculationInput Input;
        Input.UnmitigatedDamage = UnmitigatedDamage;
        Input.ShieldBypass = ShieldBypass;
        Input.CurrentShieldPoints = CurrentShieldPoints;
        Input.bShieldsActive = bShieldsActive;
        Input.ShieldDamageBlock = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShieldGeneratorDamageBlock, 0.0);
        Input.ShipDamageResistance = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShipDamageResistance, 1.0);
        Input.TypeSpecificResistance = GetResistanceForDamageType(DamageType);
        Input.GlobalDamageModifier = GlobalDamageModifier;
        Input.bIsInvulnerable = false;

        FDamageCalculationOutput Output = GameLogic::CalculateDamage(Input);

        if (Output.ShieldDamage > 0.0)
        {
            CurrentShieldPoints = Math::Max(0.0, CurrentShieldPoints - Output.ShieldDamage);
            TurnsSinceShieldDamage = 0; // resets the regen delay

            if (CurrentShieldPoints <= 0.0)
                OnShieldsDepleted.Broadcast(this);
        }

        if (Output.HullDamage > 0.0)
            ApplyHullDamage(Output.HullDamage);

        AddHeat(GameLogic::CalculateTargetEnergyBuildup(Output.HullDamage, Output.ShieldDamage, 1.0));
    }

    private float GetResistanceForDamageType(FGameplayTag DamageType)
    {
        if (DamageType == GameplayTags::DamageType_Kinetic)
            return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShipKineticResistance, 1.0);
        if (DamageType == GameplayTags::DamageType_Energy)
            return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShipEnergeticResistance, 1.0);
        if (DamageType == GameplayTags::DamageType_Explosive)
            return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShipExplosiveResistance, 1.0);

        return 1.0; // DamageType_Chemical / DamageType_Generic - flat armor only
    }

    // ==================================================================
    // Weapon fire (ties RollWeaponDamage + ApplyDamage together)
    // ==================================================================

    UFUNCTION(BlueprintCallable)
    void FireWeaponAt(FGameplayTag WeaponSlotTag, UShipStateComponent Target)
    {
        if (Target == nullptr || !EquipmentSlots.Contains(WeaponSlotTag))
            return;

        UItemWeapon Weapon = Cast<UItemWeapon>(EquipmentSlots[WeaponSlotTag].GetEquipmentFragment());
        if (Weapon == nullptr || !Weapon.IsOperational())
            return;

        float Accuracy = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_Accuracy, 0.0);
        float Evasion = Target.GetShipStat(GameplayTags::SpaceShip_Stat_Positive_Evasion, 0.0);

        float MaxDamage = Weapon.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_Weapon_MaxDamage);
        if (MaxDamage <= 0.0)
            MaxDamage = Weapon.MinDamage; // Stats entry not set up yet - fall back to a flat roll

        float RolledDamage = GameLogic::RollWeaponDamage(Weapon.MinDamage, MaxDamage, Accuracy, Evasion);

        float GlobalDamageModifier = 1.0
            + GetShipStat(GameplayTags::SpaceShip_Stat_Positive_DamageGlobal, 0.0)
            + GetDamageTypeBonus(Weapon.DamageType);

        Target.ApplyDamage(RolledDamage, Weapon.ShieldBypass, Weapon.DamageType, GlobalDamageModifier);

        AddHeat(Weapon.HeatUse); // firing costs the shooter heat too
    }

    private float GetDamageTypeBonus(FGameplayTag DamageType)
    {
        if (DamageType == GameplayTags::DamageType_Kinetic)
            return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_DamageKinetic, 0.0);
        if (DamageType == GameplayTags::DamageType_Energy)
            return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_DamageEnergetic, 0.0);
        if (DamageType == GameplayTags::DamageType_Explosive)
            return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_DamageExplosive, 0.0);
        return 0.0;
    }

    // ==================================================================
    // Self-test: assign the four definitions below in the editor, then
    // run this to sanity-check instantiate -> equip -> stat aggregation ->
    // fire -> damage -> mass in one pass, without needing a real encounter.
    // ==================================================================

    UPROPERTY(EditAnywhere, Category = "Debug|Self Test")
    UItemDefinition TestHullDefinition;

    UPROPERTY(EditAnywhere, Category = "Debug|Self Test")
    UItemDefinition TestWeaponDefinition;

    UPROPERTY(EditAnywhere, Category = "Debug|Self Test")
    UItemDefinition TestShieldGeneratorDefinition;

    UPROPERTY(EditAnywhere, Category = "Debug|Self Test")
    UItemDefinition TestFuelTankDefinition;

    UFUNCTION()
    void RunSelfTest()
    {
        if (TestHullDefinition == nullptr)
        {
            Print("RunSelfTest: assign TestHullDefinition first.");
            return;
        }

        EquipItem(GameplayTags::SpaceShip_Equipment_Hull, InstantiateItem(TestHullDefinition));

        if (TestWeaponDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_Weapon_1, InstantiateItem(TestWeaponDefinition));

        if (TestShieldGeneratorDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_ShieldGenerator, InstantiateItem(TestShieldGeneratorDefinition));

        if (TestFuelTankDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_FuelTank, InstantiateItem(TestFuelTankDefinition));

        CurrentShieldPoints = GetMaxShieldPoints();

        float mass = GetTotalShipMass();
        float maxhull = GetMaxHullPoints();
        float maxshields = GetMaxShieldPoints();
        float maxheat = GetMaxHeat();
        Print(f"Total ship mass: {mass}");
        Print(f"Max hull points: {maxhull}");
        Print(f"Max shield points: {maxshields}");
        Print(f"Max heat: {maxheat}");

        // Throwaway target so the full damage pipeline can be proven without
        // a second real ship placed in the level.
        UShipStateComponent DummyTarget = Cast<UShipStateComponent>(NewObject(this, UShipStateComponent));
        DummyTarget.EquipItem(GameplayTags::SpaceShip_Equipment_Hull, InstantiateItem(TestHullDefinition));
        DummyTarget.CurrentShieldPoints = DummyTarget.GetMaxShieldPoints();

        if (TestWeaponDefinition != nullptr)
        {
            FireWeaponAt(GameplayTags::SpaceShip_Equipment_Weapon_1, DummyTarget);

            float HP = DummyTarget.GetCurrentHullPoints();
            Print("Target hull after hit: " + HP);
            Print("Target shields after hit: " + DummyTarget.CurrentShieldPoints);
            Print("Shooter heat after firing: " + CurrentHeat);
        }
    }

}