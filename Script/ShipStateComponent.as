// ============================================================================
// ShipStateComponent.as
//
// Attached to any ship or space station actor. Owns equipment, cargo,
// the aggregated ship-wide stat cache, and the three stats that change
// during turn execution: Hull Points, Shield Points, Heat.
// This is the main application of our Attribute-Ability System (AAS)
//
// Design notes reflecting the latest round of changes:
//   - Exactly one hull, always present, always at GameplayTags::SpaceShip_Equipment_Hull.
//     UnequipItem refuses that slot; SwapItem is the only way to replace it
//     (and doubles as the way to install the very first one).
//   - Every other equipment slot (Weapon_1..N, ShieldGenerator, FuelTank, ...)
//     is granted by the equipped hull's OpenSlots the moment SwapItem installs
//     it - see GrantSlotsFromHull().
//   - Weapon damage bonuses (DamageGlobal, DamageKinetic/Energetic/Explosive)
//     are NOT part of CachedShipStats. A ship can carry several weapons with
//     different base MaxDamage and different DamageTypes, and a Multiplicative
//     modifier on "DamageGlobal" only means something relative to each
//     individual weapon's own MaxDamage - there's no single ship-wide number
//     that's correct for all of them. Instead there's a second, per-weapon
//     cache (CachedWeaponMaxDamage, keyed by slot tag) rebuilt alongside the
//     main one - see RecalculateWeaponDamageCache() and GameLogic::ApplyModifierGroup.
//   - Slot tags such as SpaceShip_Equipment_Weapon_1 are assumed to be real
//     dot-hierarchy children of SpaceShip_Equipment_Weapon, so
//     FGameplayTag::MatchesTag() works for slot/item-type compatibility.
//   - Print(FString) / f-strings are used per your RunSelfTest edit - swap if
//     your project's debug logging differs.
// ============================================================================

event void FShipHullDestroyed(UShipStateComponent Ship);
event void FShipOverheated(UShipStateComponent Ship);
event void FShipShieldsDepleted(UShipStateComponent Ship);

struct FTractorBeamProperties
{
    UPROPERTY() float Range = 750;
    UPROPERTY() float Speed = 1000;
    UPROPERTY() int SimulPickups = 1;

    FString ToString() const
    {
        return f"Range:{Range} - Speed:{Speed} - Simultaneous Pickups:{SimulPickups}";
    }
}

struct FComputedWeaponStats
{
    UPROPERTY() float MaxDamage = 1.0;
    UPROPERTY() float Range = 250.0;
    UPROPERTY() float Initiative = 10.0;
}

class UShipStateComponent : UActorComponent
{
    // Every slot this ship currently has, keyed by its gameplay tag
    // (SpaceShip_Equipment_Weapon_1, SpaceShip_Equipment_ShieldGenerator, ...).
    // GameplayTags::SpaceShip_Equipment_Hull is populated the first time
    // SwapItem() is called and stays populated forever after - see SwapItem.
    UPROPERTY() TMap<FGameplayTag, FGameItem> EquipmentSlots;
    UPROPERTY() FGameplayTag Faction;

    // General cargo hold: trade goods, spare unequipped gear, etc.
    UPROPERTY() TArray<FGameItem> Inventory;

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

    // Transient, keyed by weapon slot tag - each weapon's MaxDamage after
    // DamageGlobal/DamageType bonuses are folded in. Kept separate from
    // CachedShipStats since these bonuses resolve per-weapon, not ship-wide -
    // see the file header and RecalculateWeaponDamageCache().
    private TMap<FGameplayTag, FComputedWeaponStats> CachedWeaponMaxDamage;

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

    UPROPERTY() FShipHullDestroyed OnHullDestroyed;
    UPROPERTY() FShipOverheated OnOverheated;
    UPROPERTY() FShipShieldsDepleted OnShieldsDepleted;

    private bool bChangedLoadout = false;


    // Helper to query whether a slot is currently open on this ship
    bool IsOpenSlot(FGameplayTag SlotTag)
    {
        //TODO: Mandatory Tags
        if (SlotTag == GameplayTags::SpaceShip_Equipment_Hull)
            return true;

        UItemHull HullFragment = GetHullFragment();
        return HullFragment != nullptr && HullFragment.OpenSlots.HasTagExact(SlotTag);
    }

    bool IsSlotEmpty(FGameplayTag SlotTag)
    {
        // Slot is empty if no item entry exists in the map
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
    //Returns whether the equip was valid
    bool EquipItem(FGameplayTag SlotTag, FGameItem Item)
    {
        if (SlotTag == GameplayTags::SpaceShip_Equipment_Hull)
            return false;

        // Ensure the equipped hull actually provides this open slot
        if (!IsOpenSlot(SlotTag))
        {
            Print(f"Couldn't equip {SlotTag.ToString()}");
            return false;
        }

        if (!IsItemCompatibleWithSlot(SlotTag, Item))
            return false;

        if (SlotTag == GameplayTags::SpaceShip_Equipment_ShieldGenerator)
            CurrentShieldPoints = 0; //TODO: Mid turn equips shouldn't change turn active stats like Shields

        EquipmentSlots.Add(SlotTag, Item);
        bChangedLoadout = true;

        auto EquipmentFrag = Item.GetEquipmentFragment();
        for (FStatModifier Modifier : EquipmentFrag.GlobalModifiers)
        {
            AddGlobalModifierStat(Modifier);
        }

        MarkStatsDirty();
        return true;
    }

    //To feed to values for the TurnBasedMovementComp
    UFUNCTION(BlueprintPure)
    FTractorBeamProperties GetTractorBeamProps() 
    {
        FTractorBeamProperties Props;
        Props.Range = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_TractorBeamRange);
        Props.Speed = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_TractorBeamSpeed);
        Props.SimulPickups = Math::RoundToInt(GetShipStat(GameplayTags::SpaceShip_Stat_Positive_TractorBeamSimulPickups));

        return Props;
    }

    UFUNCTION()
    //Returns whether we can remove unequip this item slot
    bool UnequipItem(FGameplayTag SlotTag, FGameItem&out Removed)
    {
        if (SlotTag == GameplayTags::SpaceShip_Equipment_Hull)
            return false;

        if (EquipmentSlots.Contains(SlotTag))
        {
            Removed = EquipmentSlots[SlotTag];
            EquipmentSlots.Remove(SlotTag); // Completely remove entry on unequip

            auto EquipmentFrag = Removed.GetEquipmentFragment();
            for (FStatModifier Modifier : EquipmentFrag.GlobalModifiers)
            {
                RemoveGlobalModifier(Modifier);
            }

            bChangedLoadout = true;
    
            if (SlotTag == GameplayTags::SpaceShip_Equipment_ShieldGenerator)
                CurrentShieldPoints = 0; //TODO: Mid turn equips shouldn't change turn active stats like Shields

            //Unequip can either go to the Cursor Slot or to the cargo
            if (Removed.IsValid())
                Inventory.Add(Removed);
        }

        MarkStatsDirty();
        return true;
    }

    // The atomic swap: removes whatever's in SlotTag and installs NewItem in
    // the same step, so the slot is never observably empty in between. This
    // is the only way to change the hull (UnequipItem refuses it above), and
    // works the same way for any other slot too.
    UFUNCTION()
    FGameItem SwapItem(FGameplayTag SlotTag, FGameItem NewItem)
    {
        if (!IsItemCompatibleWithSlot(SlotTag, NewItem))
            return FGameItem();

        FGameItem Previous = GetItemInSlot(SlotTag);

        if (SlotTag == GameplayTags::SpaceShip_Equipment_Hull)
        {
            EquipmentSlots.Add(SlotTag, NewItem);
            GrantSlotsFromHull(); // Check for orphaned slots from old hull
        }
        else
        {
            if (!IsOpenSlot(SlotTag))
                return FGameItem();

            EquipmentSlots.Add(SlotTag, NewItem);
        }

        if (Previous.IsValid())
            Inventory.Add(Previous); //TODO: Mechanism could be defined whether it goes into Cursor Slot or to Cargo

        auto PrevEquipmentFrag = Previous.GetEquipmentFragment();
        if (PrevEquipmentFrag != nullptr)
        {
            for (FStatModifier Modifier : PrevEquipmentFrag.GlobalModifiers)
            {
                RemoveGlobalModifier(Modifier);
            }
        }

        auto EquipmentFrag = NewItem.GetEquipmentFragment();
        for (FStatModifier Modifier : EquipmentFrag.GlobalModifiers)
        {
            AddGlobalModifierStat(Modifier);
        }

        bChangedLoadout = true;

        MarkStatsDirty();
        return Previous;
    }

    UFUNCTION()
    bool EquipFromCargo(int32 CargoIndex, FGameplayTag SlotTag)
    {
        if (CargoIndex < 0 || CargoIndex >= Inventory.Num())
            return false;

        FGameItem Item = Inventory[CargoIndex];
        if (!EquipItem(SlotTag, Item))
            return false;

        Inventory.RemoveAt(CargoIndex);
        return true;
    }

    UFUNCTION()
    FGameItem InstantiateItem(UItemDefinition Definition, int32 Mass = 1)
    {
        FGameItem NewItem;
        NewItem.ItemDefinition = Definition;
        NewItem.Mass = Mass;

        if (Definition == nullptr)
            return NewItem;

        NewItem.Value = Definition.BasePrice;

        //auto EquipmentFragment = Definition.GetFragment(Template);
        //NewItem.Fragments.Add(EquipmentFragment);
        
        for (const auto TemplateFragment : Definition.Fragments)
        {
            if (TemplateFragment == nullptr)
                continue;

            NewItem.Fragments.Add(InstantiateFragment(Definition, TemplateFragment));
        }

        return NewItem;
    }

    private UItemFragment InstantiateFragment(UItemDefinition Definition, const UItemFragment Template)
    {
        if (Template == nullptr)
            return nullptr;


        //IDK how else to do this
        if (Template.IsA(UItemHull))
        {
            auto Fragment = Definition.GetFragment(UItemHull);
            auto NewFragment = Cast<UItemHull>(NewObject(this, Template.Class));
            NewFragment.CopyScriptPropertiesFrom(Fragment);
            return NewFragment;
        }

        if (Template.IsA(UItemWeapon))
        {
            auto Fragment = Definition.GetFragment(UItemWeapon);
            auto NewFragment = Cast<UItemWeapon>(NewObject(this, Template.Class));
            NewFragment.CopyScriptPropertiesFrom(Fragment);
            return NewFragment;
        }

        if (Template.IsA(UItemFuelTank))
        {
            auto Fragment = Definition.GetFragment(UItemFuelTank);
            auto NewFragment = Cast<UItemFuelTank>(NewObject(this, Template.Class));
            NewFragment.CopyScriptPropertiesFrom(Fragment);
            return NewFragment;
        }

        auto Fragment = Definition.GetFragment(UItemEquipment);
        auto NewFragment = Cast<UItemEquipment>(NewObject(this, Template.Class));
        NewFragment.CopyScriptPropertiesFrom(Fragment);
        return NewFragment;
    }

    void MarkStatsDirty()
    {
        bStatsDirty = true;
    }

    // FGValue matters: additive stats (MaxShieldPoints, EnergyCapacity)
    // should default to 0 when absent, but multiplicative ones (resistances)
    // need to default to 1 or missing equipment would zero out all damage.
    UFUNCTION()
    float GetShipStat(FGameplayTag StatTag, float DefaultValue = 0.0)
    {
        //Caused infinite recursion when getting stats before clearing the dirty flag, stats are recalculated every turn anyway
        //RecalculateShipStatsIfDirty();
        return CachedShipStats.Contains(StatTag) ? CachedShipStats[StatTag] : DefaultValue;
    }

    private void RecalculateShipStatsIfDirty()
    {
        if (!bStatsDirty)
            return;
        RecalculateShipStats();
        bStatsDirty = false;
    }

    private void RecalculateShipStats()
    {
        CachedShipStats.Empty();
        CachedWeaponMaxDamage.Empty();

        for (const auto& BaseStat : CharacterStats)
            CachedShipStats.Add(BaseStat.StatTag, BaseStat.BaseValue);

        TArray<FGameplayTag> SlotTags;
        EquipmentSlots.GetKeys(SlotTags);

        for (FGameplayTag SlotTag : SlotTags)
        {
            //Weapons can't be combined into one single cached stat
            if (SlotTag.MatchesTag(GameplayTags::SpaceShip_Equipment_Weapon))
                continue;

            FGameItem Item = EquipmentSlots[SlotTag];
            if (!Item.IsValid())
                continue;

            UItemEquipment Fragment = Item.GetEquipmentFragment();
            if (Fragment == nullptr)
                continue;

            Fragment.RecalculateStats();

            for (const auto& Stat : Fragment.Stats)
            {
                if (Stat.StatTag == GameplayTags::SpaceShip_Stat_Positive_MaximumDurability)
                    continue;

                float Existing = CachedShipStats.Contains(Stat.StatTag) ? CachedShipStats[Stat.StatTag] : 0.0;
                CachedShipStats.Add(Stat.StatTag, Existing + Stat.Value);
            }
        }
        float Mass = CalculateTotalShipMass();
        CachedShipStats.Add(GameplayTags::SpaceShip_Stat_Negative_ShipMass, Mass);

        // Ship-wide effects (Acrine, active effects/stimulants) fold on top last.
        TArray<FGameplayTag> AggregatedTags;
        CachedShipStats.GetKeys(AggregatedTags);
        for (FGameplayTag Tag : AggregatedTags)
            CachedShipStats[Tag] = GameLogic::ApplyModifiers(CachedShipStats[Tag], Tag, GlobalModifiers);

        CachedShipStats.Add(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed, GetShipSpeed());

        RecalculateWeaponDamageCache(SlotTags);
    }

    // Per weapon: BaseMaxDamage * (1 + DamageGlobal Mult) * (1 + <DamageType> Mult) + DamageGlobal Flat + <DamageType> Flat.
    // Can't reuse CachedShipStats for this - see the file header.
    private void RecalculateWeaponDamageCache(const TArray<FGameplayTag>& SlotTags)
    {
            for (FGameplayTag SlotTag : SlotTags)
        {
            FGameItem Item = EquipmentSlots[SlotTag];
            if (!Item.IsValid())
                continue;

            UItemWeapon Weapon = Cast<UItemWeapon>(Item.GetEquipmentFragment());
            if (Weapon == nullptr)
                continue;

            float BaseMaxDamage = Weapon.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_Weapon_MaxDamage);
            if (BaseMaxDamage <= 0.0)
                BaseMaxDamage = Weapon.MinDamage; // Stats entry not set up yet - fall back to a flat roll

            TArray<FGameplayTag> DamageBonusTags;
            DamageBonusTags.Add(GameplayTags::SpaceShip_Stat_Positive_DamageGlobal);
            FGameplayTag TypeTag = GetDamageTypeTag(Weapon.DamageType);
            if (TypeTag.IsValid())
                DamageBonusTags.Add(TypeTag);

            float BaseWeaponRange = Weapon.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_Weapon_Range);
            FComputedWeaponStats WeaponStats;
            WeaponStats.MaxDamage = GameLogic::ApplyModifierGroup(BaseMaxDamage, DamageBonusTags, GlobalModifiers);
            WeaponStats.Range = GameLogic::ApplyModifiers(BaseWeaponRange, GameplayTags::SpaceShip_Stat_Positive_Weapon_Range, GlobalModifiers);
            CachedWeaponMaxDamage.Add(SlotTag, WeaponStats);
        }
    }

    // Effective MaxDamage for the weapon in WeaponSlotTag, DamageGlobal and
    // type-specific bonuses already folded in. What FireWeaponAt rolls against.
    UFUNCTION(BlueprintPure)
    float GetEffectiveWeaponMaxDamage(FGameplayTag WeaponSlotTag)
    {
        RecalculateShipStatsIfDirty();
        return CachedWeaponMaxDamage.Contains(WeaponSlotTag) ? CachedWeaponMaxDamage[WeaponSlotTag].MaxDamage : 0.0;
    }

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

    void AddGlobalModifierStat(FStatModifier Modifier)
    {
        GlobalModifiers.Add(Modifier);
        MarkStatsDirty();
    }

    UFUNCTION()
    void AddGlobalModifier(FGameplayTag SourceType, FGameplayTag StatTag, EStatType Type, float Value = 0.0)
    {
        FStatModifier NewModifier;
        NewModifier.SourceType = SourceType;
        NewModifier.StatTag = StatTag;
        NewModifier.Type = Type;
        NewModifier.Value = Value;
        AddGlobalModifierStat(NewModifier);
    }

    UFUNCTION()
    void RemoveGlobalModifier(FStatModifier GlobalModifier, int AmountToRemove=1)
    {
        int Count = 0;
        for (int32 i = GlobalModifiers.Num() - 1; i >= 0; i--)
        {
            if (GlobalModifiers[i] == GlobalModifier)
            {
                GlobalModifiers.RemoveAt(i);
                Count++;
                if (AmountToRemove == Count)
                    break;
            }
        }
        MarkStatsDirty();
    }

    UFUNCTION()
    void RemoveAllGlobalModifiersByStat(FGameplayTag Stat)
    {
        for (int i = GlobalModifiers.Num() - 1; i >= 0; i--)
        {
            if (GlobalModifiers[i].StatTag.MatchesTagExact(Stat))
                GlobalModifiers.RemoveAt(i);
        }
    }

    private UItemHull GetHullFragment()
    {
        return UGameUtility::GetItemFragment(EquipmentSlots[GameplayTags::SpaceShip_Equipment_Hull].Fragments, UItemHull);
    }

    private UItemFuelTank GetFuelTankFragment()
    {
        return UGameUtility::GetItemFragment(EquipmentSlots[GameplayTags::SpaceShip_Equipment_FuelTank].Fragments, UItemFuelTank);
    }

    private UItemWeapon GetWeaponFragment(FGameplayTag WeaponSlot)
    {
        return UGameUtility::GetItemFragment(EquipmentSlots[WeaponSlot].Fragments, UItemWeapon);
    }

    private void GrantSlotsFromHull()
    {
        UItemHull HullFragment = GetHullFragment();
        if (HullFragment == nullptr)
            return;

        // Unequip items from slots that the new hull does NOT support
        TArray<FGameplayTag> CurrentSlotTags;
        EquipmentSlots.GetKeys(CurrentSlotTags);

        for (FGameplayTag SlotTag : CurrentSlotTags)
        {
            if (SlotTag == GameplayTags::SpaceShip_Equipment_Hull) //TODO: Mandatory Tags
                continue;

            if (!HullFragment.OpenSlots.HasTagExact(SlotTag))
            {
                FGameItem Whatever = FGameItem();
                UnequipItem(SlotTag, Whatever); // Moves item to CargoHold and removes key from EquipmentSlots
            }
        }

    }

    // ==================================================================
    // Mass
    // ==================================================================

    // Sum of every equipped item's mass (via FGameItem::GetItemMass) plus
    // everything in the cargo hold, except the hull, which uses
    // UItemHull::GetHullMass() instead.
    UFUNCTION(BlueprintPure)
    float CalculateTotalShipMass()
    {
        float TotalMass = 0.0;

        UItemHull HullFragment = GetHullFragment();
        if (HullFragment != nullptr)
            TotalMass += HullFragment.GetHullMass();

        TArray<FGameplayTag> SlotTags;
        EquipmentSlots.GetKeys(SlotTags);
        SlotTags.Remove(GameplayTags::SpaceShip_Equipment_Hull);

        for (FGameplayTag SlotTag : SlotTags)
        {
            FGameItem Item = EquipmentSlots[SlotTag];
            if (!Item.IsValid())
                continue;

            TotalMass += Item.Mass;
        }

        for (const auto& CargoItem : Inventory)
            TotalMass += CargoItem.Mass;

        return Math::RoundToFloat(TotalMass);
    }

    UFUNCTION(BlueprintPure)
    float GetShipSpeed(float SlowdownMultiplier = 1.0)
    {
        UItemHull HullFragment = GetHullFragment();
        if (HullFragment == nullptr)
            return 0.0;

        // ShipMaxSpeed comes from the hull's own MaxSpeed Value, not
        // GetShipStat() - it's item-local BaseValue + this item's own
        // Upgrade/Micromodule Modifiers only. Ship-wide bonuses (Acrine,
        // Artifacts, Stimulants) are handled separately below and must NOT
        // be folded in here too, or they'd get counted twice.
        float ShipMaxSpeed = HullFragment.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed);

        // Global/Acrine speed bonuses (Psi Matter Accelerator, Stimulant
        // Gaalian Alacrity, an Acrine +50 Speed modifier, ...) live in
        // GlobalModifiers, not on any item's Stats - kept separate from
        // ShipMaxSpeed above so they're never double-counted.
        FModifierComponents SpeedBonuses = GameLogic::GetModifierComponents(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed, GlobalModifiers);

        float CalculatedSpeed = GameLogic::GetShipSpeed(
            ShipMaxSpeed,
            GetShipStat(GameplayTags::SpaceShip_Stat_Negative_ShipMass),
            SlowdownMultiplier,
            GetCurrentSpeedMultiplier(),
            SpeedBonuses.MultiplicativeFactor,
            SpeedBonuses.AdditiveSum);

        return Math::RoundToFloat(CalculatedSpeed);
    }

    UFUNCTION(BlueprintPure)
    float GetCurrentHullPoints()
    {
        UItemHull HullFragment = GetHullFragment();
        return HullFragment != nullptr ? HullFragment.CurrentDurability : 0.0;
    }

    UFUNCTION(BlueprintPure)
    float GetMaxHullPoints()
    {
        UItemHull HullFragment = GetHullFragment();
        return HullFragment != nullptr ? HullFragment.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_MaximumDurability) : 0.0;
    }

    private void ApplyHullDamage(float HullDamage)
    {
        UItemHull HullFragment = GetHullFragment();
        if (HullFragment == nullptr)
            return; // no hull, nothing to damage against

        //Inputting a negative value (for example a self healing weapon) will not overflow capacity
        HullFragment.CurrentDurability = Math::Min(HullFragment.CurrentDurability - HullDamage, HullFragment.GetMaximumDurability());

        if (HullFragment.CurrentDurability <= 0.0)
            OnHullDestroyed.Broadcast(this);
    }

    private void ApplyShieldDamage(float ShieldDamage)
    {
        CurrentShieldPoints = Math::Max(0.0, CurrentShieldPoints - ShieldDamage);
        TurnsSinceShieldDamage = 0; // resets the regen delay

        if (CurrentShieldPoints <= 0.0)
            OnShieldsDepleted.Broadcast(this);
    }

    // 0-100. Feeds GetReliabilitySpeedMultiplier from ShipCombatMath.as
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

    float GetMaxShieldPoints()
    {
        return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_MaxShieldPoints, 0.0);
    }

    UFUNCTION()
    void SetShieldsActive(bool bActive)
    {
        bShieldsActive = bActive;
    }

    float GetMaxHeat()
    {
        return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_HeatCapacity, 0.0);
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

    void SetAfterburners(bool Active=false)
    {
        FStatModifier Afterburner = FStatModifier(GameplayTags::StatSource_ActiveEffect,
            GameplayTags::SpaceShip_Stat_Positive_MaxSpeed, EStatType::Multiplicative, 1.0);
        //1.0 -> +100% -> 2x increase
        FStatModifier Degradation = FStatModifier(GameplayTags::StatSource_ActiveEffect, 
            GameplayTags::SpaceShip_Stat_Negative_DurabilityDegradation, EStatType::Multiplicative, 50.0);

        UItemHull Hull = GetHullFragment();

        if(Active)
        {
            AddGlobalModifierStat(Afterburner);
            Hull.AddModifier(Degradation);
        }
        else
        {
            RemoveGlobalModifier(Afterburner);
            Hull.RemoveModifier(Degradation);
        }
    }


    // Call once per WEGO turn resolution, after orders have been applied.
    UFUNCTION()
    void AdvanceTurn()
    {
        RecalculateShipStatsIfDirty();

        float Dissipation = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_HeatDissipation, 0.0);
        CurrentHeat = Math::Max(0.0, CurrentHeat - Dissipation);
        if (bIsOverheated && CurrentHeat < GetMaxHeat())
            bIsOverheated = false;

        TurnsSinceShieldDamage++;
        float MaxShields = GetMaxShieldPoints();
        if (bShieldsActive && MaxShields > 0.0 && TurnsSinceShieldDamage >= ShieldRegenDelayTurns)
        {
            CurrentShieldPoints = Math::Min(MaxShields, CurrentShieldPoints + MaxShields * ShieldRegenPercentPerTurn);
        }

        if (bChangedLoadout)
        {
            
            bChangedLoadout = false;
        }
    }

    UFUNCTION()
    FDamageCalculationOutput ApplyDamage(float UnmitigatedDamage, float ShieldBypass, FGameplayTag DamageType, float GlobalDamageModifier = 1.0)
    {
        FDamageCalculationInput Input;
        Input.SourceUnmitigatedDamage = UnmitigatedDamage;
        Input.SourceShieldBypass = ShieldBypass;
        Input.SourceGlobalDamageModifier = GlobalDamageModifier;
        Input.TargetCurrentShields = CurrentShieldPoints;
        Input.bTargetHasShieldsActive = bShieldsActive;
        Input.TargetShieldDamageBlock = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShieldGeneratorDamageBlock, 0.0);
        Input.TargetShipDamageResistance = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShipDamageResistance, 1.0);
        Input.TargetTypeSpecificResistance = GetResistanceForDamageType(DamageType);
        Input.bTargetIsInvulnerable = false;

        FDamageCalculationOutput Output = GameLogic::CalculateDamage(Input);

        if (Output.ShieldDamage > 0.0)
            ApplyShieldDamage(Output.ShieldDamage);

        if (Output.HullDamage > 0.0)
            ApplyHullDamage(Output.HullDamage);

        AddHeat(GameLogic::CalculateTargetEnergyBuildup(Output.HullDamage, Output.ShieldDamage, 1.0));

        return Output;
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
    
    UFUNCTION()
    int FireWeaponAt(FGameplayTag WeaponSlotTag, UShipStateComponent Target)
    {
        if (Target == nullptr || !EquipmentSlots.Contains(WeaponSlotTag))
            return -1;

        UItemWeapon Weapon = GetWeaponFragment(WeaponSlotTag);//Cast<UItemWeapon>(EquipmentSlots[WeaponSlotTag].GetEquipmentFragment());
        if (Weapon == nullptr || !Weapon.IsOperational())
            return - 1;

        float Accuracy = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_Accuracy, 0.0);
        float Evasion = Target.GetShipStat(GameplayTags::SpaceShip_Stat_Positive_Evasion, 0.0);

        // Per-weapon: this specific weapon's own MaxDamage with DamageGlobal
        // and its own DamageType's bonus already folded in - see
        // RecalculateWeaponDamageCache() and the file header for why this
        // can't be a plain GetShipStat() lookup.
        float EffectiveMaxDamage = GetEffectiveWeaponMaxDamage(WeaponSlotTag);

        float RolledDamage = GameLogic::RollWeaponDamage(Weapon.MinDamage, EffectiveMaxDamage, Accuracy, Evasion);

        // The only bonus still resolved as a true multiplier at damage-resolution
        // time is the faction bonus - it depends on who we're shooting at, so
        // unlike the flat bonuses above it can't be baked into MaxDamage ahead
        // of time.
        float GlobalDamageModifier = 1.0 + GetShipStat(GetFactionTargetTag(Target.Faction), 0.0);

        FDamageCalculationOutput Output = Target.ApplyDamage(RolledDamage, Weapon.ShieldBypass, Weapon.DamageType, GlobalDamageModifier);

        AddHeat(Weapon.HeatUse); // firing costs the shooter heat too

        return Math::RoundToInt(Output.HullDamage);
    }

    private FGameplayTag GetFactionTargetTag(FGameplayTag TargetFaction)
    {
        if (GameplayTags::Race_Coalition.MatchesTag(TargetFaction))
        {
            return GameplayTags::SpaceShip_Stat_Positive_DamageCoalition;
        }
        else if (GameplayTags::Race_Dominator.MatchesTag(TargetFaction))
        {
            return GameplayTags::SpaceShip_Stat_Positive_DamageDominator;
        }
        return FGameplayTag();
    }

    // RENAMED from GetDamageTypeBonus: returns the tag to look up rather than
    // the resolved float, matching GetFactionTargetTag's shape - the bonus is
    // now read via GetShipStat() at the FireWeaponAt call site instead of a
    // second, separate resolution path.
    private FGameplayTag GetDamageTypeTag(FGameplayTag DamageType)
    {
        if (DamageType == GameplayTags::DamageType_Kinetic) return GameplayTags::SpaceShip_Stat_Positive_DamageKinetic;
        if (DamageType == GameplayTags::DamageType_Energy) return GameplayTags::SpaceShip_Stat_Positive_DamageEnergetic;
        if (DamageType == GameplayTags::DamageType_Explosive) return GameplayTags::SpaceShip_Stat_Positive_DamageExplosive;
        return FGameplayTag();
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
    
    UPROPERTY(EditAnywhere, Category = "Debug|Self Test")
    UItemDefinition TestTractorBeamDefinition;

    UFUNCTION()
    void RunSelfTest()
    {
        FGameItem Hull = InstantiateItem(TestHullDefinition);
        UItemHull Fragment = UGameUtility::GetItemFragment(Hull.Fragments, UItemHull);
        Hull.Mass = Math::RoundToInt(Fragment.GetHullMass());
        float Speed1 = Fragment.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed);
        float Dur1 = Fragment.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_MaximumDurability);

        //Fragment.AddModifier(GameplayTags::StatSource_Upgrade, GameplayTags::SpaceShip_Stat_Positive_MaxSpeed, EStatType::Multiplicative,0.31);
        Fragment.AddModifier(GameplayTags::StatSource_Micromodule1, GameplayTags::SpaceShip_Stat_Positive_MaximumDurability, EStatType::Multiplicative, 0.2);
        Fragment.RecalculateStats();
        float Speed2 = Fragment.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed);
        Print(f"Speed:{Speed1}->{Speed2}");
        float Dur2 = Fragment.GetStatValue(GameplayTags::SpaceShip_Stat_Positive_MaximumDurability);
        Print(f"MaxDur:{Dur1}->{Dur2}\nCurrentDur:{Fragment.CurrentDurability}");

        //AddGlobalModifier(GameplayTags::StatSource_Artifact, GameplayTags::SpaceShip_Stat_Positive_DamageKinetic, EStatType::Additive, 10);
        
        SwapItem(GameplayTags::SpaceShip_Equipment_Hull, InstantiateItem(TestHullDefinition));
    
        if (TestWeaponDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_Weapon_1, InstantiateItem(TestWeaponDefinition));

        if (TestShieldGeneratorDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_ShieldGenerator, InstantiateItem(TestShieldGeneratorDefinition));

        if (TestFuelTankDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_FuelTank, InstantiateItem(TestFuelTankDefinition));

        if (TestTractorBeamDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_TractorBeam, InstantiateItem(TestTractorBeamDefinition));


        FStatAttribute Accuracy = FStatAttribute(GameplayTags::SpaceShip_Stat_Positive_Accuracy, 0.0);
        CharacterStats.Add(Accuracy);

        AddGlobalModifier(GameplayTags::StatSource_Artifact, GameplayTags::SpaceShip_Stat_Negative_ShipMass, EStatType::Multiplicative, 3.0);
        SetAfterburners(true);
        bChangedLoadout = true;
        RecalculateShipStats();

        //RemoveAllGlobalModifiersByStat(GameplayTags::SpaceShip_Stat_Negative_ShipMass);
        //RecalculateShipStats();
        CurrentShieldPoints = GetMaxShieldPoints();

        FTractorBeamProperties TB = GetTractorBeamProps();
        Print(TB.ToString());

        /*
        TArray<FGameplayTag> Stats;
        CachedShipStats.GetKeys(Stats);
        for (FGameplayTag Stat : Stats)
        {
            Print(f"Stat:{Stat}={CachedShipStats[Stat]}", 20);
        }*/
        for (FStatModifier Stat : GlobalModifiers)
        {
            Print(f"Stat:{Stat.StatTag}={Stat.Value}", 20);
        }


        
        float CurrentMass = GetShipStat(GameplayTags::SpaceShip_Stat_Negative_ShipMass);
        float MaxHull = GetMaxHullPoints();
        float HP = GetCurrentHullPoints();
        float MaxShields = GetMaxShieldPoints();
        float MaxHeat = GetMaxHeat();
        float Speed = GetShipSpeed();

        Print(f"Mass: {CurrentMass}", 20);
        Print(f"HP: {HP}/{MaxHull}", 20);
        Print(f"SP: {CurrentShieldPoints}/{MaxShields}", 20);
        Print(f"Speed: {Speed}", 20);
        Print("-------------\nOUR VALUES\n------------", 20);

        // Throwaway target so the full damage pipeline can be proven without
        // a second real ship placed in the level.
        UShipStateComponent DummyTarget = Cast<UShipStateComponent>(NewObject(this, UShipStateComponent));
        DummyTarget.SwapItem(GameplayTags::SpaceShip_Equipment_Hull, InstantiateItem(TestHullDefinition));
        DummyTarget.CurrentShieldPoints = DummyTarget.GetMaxShieldPoints();

        FStatAttribute Evasion = FStatAttribute();
        Evasion.BaseValue = 0;
        Evasion.Value= 0;
        Evasion.StatTag = GameplayTags::SpaceShip_Stat_Positive_Evasion;
        DummyTarget.CharacterStats.Add(Evasion);
        DummyTarget.RecalculateShipStats();

        if (TestWeaponDefinition != nullptr)
        {
            int Damage = FireWeaponAt(GameplayTags::SpaceShip_Equipment_Weapon_1, DummyTarget);
            
            float D_MaxHull = DummyTarget.GetMaxHullPoints();
            float D_HP = DummyTarget.GetCurrentHullPoints();
            float D_MaxShields = DummyTarget.GetMaxShieldPoints();
            float D_MaxHeat = DummyTarget.GetMaxHeat();

            Print(f"HP: {D_HP}/{D_MaxHull}", 20);
            Print(f"SP: {DummyTarget.CurrentShieldPoints}/{D_MaxShields}", 20);
            Print(f"Heat: {DummyTarget.CurrentHeat}/{D_MaxHeat}", 20);
            Print(f"Damaged target for: {Damage}", 20);
            Print("-------------\nDUMMY VALUES\n------------", 20);
            
            Print(f"My Heat: {CurrentHeat}/{MaxHeat}", 20);
        }
    }

    UFUNCTION()
    void Init()
    {

    }

}
