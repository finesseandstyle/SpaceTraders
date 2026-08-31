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
//   - Slot tags such as SpaceShip_Equipment_Weapon_01 are assumed to be real
//     dot-hierarchy children of SpaceShip_Equipment_Weapon, so
//     FGameplayTag::MatchesTag() works for slot/item-type compatibility.
// ============================================================================

event void FShipHullDestroyed(UShipStateComponent Ship);
event void FShipOverheated(UShipStateComponent Ship);
event void FShipShieldsDepleted();
event void FShipSpeedChanged(float NewSpeed);
event void FShipShieldPointsChanged(float NewShieldPoints, float MaxShieldPoints, float Delta);
event void FShipHullPointsChanged(float NewHullPoints, float MaxHullPoints, float Delta);
event void FShipHeatChanged(float NewHeat, float MaxHeat);

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

struct FActiveEffectRule //AngelScript automatically extends FTableRow, AS doesn't allow extending structs anyway
{
    UPROPERTY() FGameplayTag RequiredTag; // Optional, requires a certain stat or tag on the ship to be able to activate
    UPROPERTY() FGameplayTag Name;
    UPROPERTY() float MaxValue = 1; // -1 : No max value
    UPROPERTY() float MaxStacks = 1; // A value of 0 means we can't stack like for bool values
    UPROPERTY() float MaxDuration = 5;
    UPROPERTY() float DefaultValue = 0.0;
    
    UPROPERTY() FString DevDescription;
}

struct FActiveEffect
{
    UPROPERTY() float Duration = 1.0; //In Turns, -1 means forever. Every turn we subtract 1, when it reaches 0, it's eliminated
    UPROPERTY() float Value = 0.0; //To use booleans use 0.0 or 1.0. Otherwise -> Stacks * MaxValue
    UPROPERTY() float Stacks = 1.0; //Magnitude of the effect

    FActiveEffect(float InDuration, float InValue, float InStacks)
    {
        Duration = InDuration;
        Value = InValue;
        Stacks = InStacks;
    }
}

struct FDamageSpec
{
    UPROPERTY() FGameplayTag DamageType = GameplayTags::DamageType_Generic;
    UPROPERTY() float UnmitigatedDamage = 0.0;
    UPROPERTY() float ShieldBypass = 0.0;
    UPROPERTY() float GlobalDamageModifier = 1.0;

    FDamageSpec(FGameplayTag InDamageType, float InUnmitigatedDamage, float InShieldBypass=0.0, float InGlobalDamageModifier=1.0)
    {
        DamageType = InDamageType;
        UnmitigatedDamage = InUnmitigatedDamage;
        ShieldBypass = InShieldBypass;
        GlobalDamageModifier = InGlobalDamageModifier;
    }
}

//Snapshotting a weapon's stat profile that will be passed on to the projectile actor
struct FProjectileDamageSpec
{
    UPROPERTY() USceneComponent HomingTarget;
    UPROPERTY() FGameplayTag DamageType = GameplayTags::DamageType_Generic;
    UPROPERTY() FGameplayTag WeaponSlot = GameplayTags::SpaceShip_Equipment_Weapon; //1 - 10
    UPROPERTY() float MinDamage = 0.0;
    UPROPERTY() float MaxDamage = 0.0;
    UPROPERTY() float Accuracy = 0.0;
    UPROPERTY() float ShieldBypass = 0.0;
    UPROPERTY() int HomingDelay_Turns = 1;
    

    FProjectileDamageSpec(USceneComponent InHomingTarget, FGameplayTag InDamageType, FGameplayTag InWeaponSlot, float InMinDamage, float InMaxDamage, float InAccuracy, float InShieldBypass=0.0, int InHomingDelay=1)
    {
        HomingTarget = InHomingTarget;
        DamageType = InDamageType;
        WeaponSlot = InWeaponSlot;
        MinDamage = InMinDamage;
        MaxDamage = InMaxDamage;
        Accuracy = InAccuracy;
        ShieldBypass = InShieldBypass;
        HomingDelay_Turns = InHomingDelay;
    }
}

enum EWeaponState {
    Unequipped,
    Equipped,
    Broken,
    Disabled, //by debuffs for example
    Pressed, //UI only for the player when they initially press a weapon before targeting
    Targeting
}

class UShipStateComponent : UActorComponent
{
    UPROPERTY() FGameplayTag Faction;
    UPROPERTY() TMap<FGameplayTag, FGameItem> EquipmentSlots; //Hull, Engine, Droid, Radar, Artifacts, Weapons, etc.
    UPROPERTY() TArray<FGameItem> Inventory;
    UPROPERTY() TArray<FStatAttribute> CharacterStats; //Accuracy, Evasion, Negotiation, Leadership, Engineering
    UPROPERTY() TArray<FStatModifier> GlobalModifiers; //+5 kinetic damage, +20% speed, -10% mass, +15 droid repair, +1 acc
    private TMap<FGameplayTag, float> CachedShipStats; //Final Stats for ship wide stats, recalculated only when needed.
    private TMap<FGameplayTag, FComputedWeaponStats> CachedWeaponStats; //Calculated Stats for each individual weapon slot
    UPROPERTY() TMap<FGameplayTag, FActiveEffect> ActiveEffects; 
    UPROPERTY() TMap<FGameplayTag, FActiveEffect> QueuedActiveEffects; //when we want to queue abilities / effects for next turn
    UPROPERTY() TArray<FWeaponShot> WeaponOrders; //We manually assign each index to the weapon's slot number
    private bool bStatsDirty = true;

    // ------------------------------------------------------------------
    // Turn-mutable combat state
    // ------------------------------------------------------------------
    //Swapping hulls will reset your HP to the item's durability, so it doesn't need to be here
    UPROPERTY() float CurrentShieldPoints = 0.0;
    UPROPERTY() float CurrentHeat = 0.0;

    UPROPERTY() FShipHullDestroyed OnHullDestroyed;
    UPROPERTY() FShipOverheated OnOverheated;
    UPROPERTY() FShipShieldsDepleted OnShieldsDepleted;
    UPROPERTY() FShipSpeedChanged OnSpeedChanged;
    UPROPERTY() FShipShieldPointsChanged OnShieldsChanged;
    UPROPERTY() FShipHullPointsChanged OnHPChanged;
    UPROPERTY() FShipHeatChanged OnHeatChanged;

    private bool bChangedLoadout = false;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        EquipmentSlots.Add(GameplayTags::SpaceShip_Equipment_Hull, FGameItem());
        for (int32 i = 0; i < 6; i++)
        {
            WeaponOrders.Add(FWeaponShot(this, nullptr, this.GetOwner().RootComponent, 
            nullptr, EWeaponFiringType::Projectile, 30));
        }
    }

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
        Props.Range = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_TractorBeamRange) * 10;
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
    // Ship Stats should default to a value otherwise they'll have flat modifiers 
    // even if the respective equipment is missing
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

        //if (CachedShipStats.Contains(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed))
            //Print(f"{GameplayTags::SpaceShip_Stat_Positive_MaxSpeed} - {CachedShipStats[GameplayTags::SpaceShip_Stat_Positive_MaxSpeed]}", 20);
        RecalculateShipStats();
        bStatsDirty = false;
    }

    private void RecalculateShipStats()
    {
        CachedShipStats.Empty();
        CachedWeaponStats.Empty();

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

        UpdateSpeedStat();

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

            float BaseMaxDamage = Weapon.GetItemStat(GameplayTags::SpaceShip_Stat_Positive_Weapon_MaxDamage);
            if (BaseMaxDamage <= 0.0)
                BaseMaxDamage = Weapon.MinDamage; // Stats entry not set up yet - fall back to a flat roll

            TArray<FGameplayTag> DamageBonusTags;
            DamageBonusTags.Add(GameplayTags::SpaceShip_Stat_Positive_DamageGlobal);
            FGameplayTag TypeTag = GetDamageTypeTag(Weapon.DamageType);
            if (TypeTag.IsValid())
                DamageBonusTags.Add(TypeTag);

            float BaseWeaponRange = Weapon.GetItemStat(GameplayTags::SpaceShip_Stat_Positive_Weapon_Range);
            FComputedWeaponStats WeaponStats;
            WeaponStats.MaxDamage = GameLogic::ApplyModifierGroup(BaseMaxDamage, DamageBonusTags, GlobalModifiers);
            WeaponStats.Range = GameLogic::ApplyModifiers(BaseWeaponRange, GameplayTags::SpaceShip_Stat_Positive_Weapon_Range, GlobalModifiers);
            CachedWeaponStats.Add(SlotTag, WeaponStats);
        }
    }

    // Effective MaxDamage for the weapon in WeaponSlotTag, DamageGlobal and
    // type-specific bonuses already folded in. What FireWeaponAt rolls against.
    UFUNCTION(BlueprintPure)
    float GetEffectiveWeaponMaxDamage(FGameplayTag WeaponSlotTag)
    {
        RecalculateShipStatsIfDirty();
        return CachedWeaponStats.Contains(WeaponSlotTag) ? CachedWeaponStats[WeaponSlotTag].MaxDamage : 0.0;
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
        return Cast<UItemHull>(UGameUtility::GetItemFragment(EquipmentSlots[GameplayTags::SpaceShip_Equipment_Hull].Fragments, UItemHull));
    }

    private UItemFuelTank GetFuelTankFragment()
    {
        return Cast<UItemFuelTank>(UGameUtility::GetItemFragment(EquipmentSlots[GameplayTags::SpaceShip_Equipment_FuelTank].Fragments, UItemFuelTank));
    }

    private UItemWeapon GetWeaponFragment(FGameplayTag WeaponSlot)
    {
        return Cast<UItemWeapon>(UGameUtility::GetItemFragment(EquipmentSlots[WeaponSlot].Fragments, UItemWeapon));
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
    float GetShipSpeed()
    {
        UItemHull HullFragment = GetHullFragment();
        if (HullFragment == nullptr)
            return 0.0;

        // ShipMaxSpeed comes from the hull's own MaxSpeed Value, not
        // GetShipStat() - it's item-local BaseValue + this item's own
        // Upgrade/Micromodule Modifiers only. Ship-wide bonuses (Acrine,
        // Artifacts, Stimulants) are handled separately below and must NOT
        // be folded in here too, or they'd get counted twice.
        float ShipMaxSpeed = HullFragment.GetItemStat(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed);
        float SlowdownMultiplier = 1 - GetActiveEffectValue(GameplayTags::SpaceShip_ActiveEffect_Slowdown, 0.0);

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

    UFUNCTION()
    float GetActiveEffectValue(FGameplayTag ActiveEffect, float DefaultValue = 0.0)
    {
        FActiveEffect temp;
        //Ignoring Max Value from DT for now, we'll setup a proper way to parse values later
        if (ActiveEffects.Find(ActiveEffect, temp))
        {
            return temp.Value * temp.Stacks;
        }

        return DefaultValue;
    }

    UFUNCTION()
    float GetQueuedActiveEffectValue(FGameplayTag ActiveEffect, float DefaultValue = 0.0)
    {
        FActiveEffect temp;
        //Ignoring Max Value from DT for now, we'll setup a proper way to parse values later
        if (!QueuedActiveEffects.Contains(ActiveEffect))
        {
            return GetActiveEffectValue(ActiveEffect, DefaultValue);
        }

        if (QueuedActiveEffects.Find(ActiveEffect, temp))
        {
            return temp.Value * temp.Stacks;
        }

        return DefaultValue;
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
        return HullFragment != nullptr ? HullFragment.GetItemStat(GameplayTags::SpaceShip_Stat_Positive_MaximumDurability) : 0.0;
    }

    UFUNCTION(BlueprintPure)
    float GetMaxShieldPoints()
    {
        return GetShipStat(GameplayTags::SpaceShip_Stat_Positive_MaxShieldPoints);
    }

    UFUNCTION()
    void ApplyHullDamage(float HullDamage)
    {
        UItemHull HullFragment = GetHullFragment();
        if (HullFragment == nullptr)
            return; // no hull, nothing to damage against

        //Inputting a negative value (for example a self healing weapon) will not overflow capacity
        HullFragment.CurrentDurability = Math::Min(HullFragment.CurrentDurability - HullDamage, HullFragment.GetMaximumDurability());

        OnHPChanged.Broadcast(HullFragment.CurrentDurability, HullFragment.GetMaximumDurability(), -HullDamage);

        if (HullFragment.CurrentDurability <= 0.0)
            OnHullDestroyed.Broadcast(this);
    }

    UFUNCTION()
    void ApplyShieldDamage(float ShieldDamage)
    {
        CurrentShieldPoints = Math::Max(0.0, CurrentShieldPoints - ShieldDamage);
        float Delay = GetShipStat(GameplayTags::SpaceShip_Stat_Negative_ShieldRegenDelay);

        OnShieldsChanged.Broadcast(CurrentShieldPoints, GetMaxShieldPoints(), -ShieldDamage);

        if (CurrentShieldPoints <= 0.0)
        {
            OnShieldsDepleted.Broadcast();
            Delay += 1; //Shield Break
        }
        
        ActiveEffects.Add(GameplayTags::SpaceShip_ActiveEffect_LastShieldHit, FActiveEffect(Delay, 1.0, 1.0)); // resets the regen delay
    }

    UFUNCTION()
    float GetWeaponRange(FGameplayTag WeaponSlot)
    {
        if (!EquipmentSlots.Contains(WeaponSlot))
            return 0.0;
        FComputedWeaponStats WeaponStats;
        // Fetch weapon ranges from ShipStateComponent using slot tag
        CachedWeaponStats.Find(WeaponSlot, WeaponStats);
        return WeaponStats.Range;
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

    UFUNCTION()
    bool SetShieldsActive(EShipMovementState State, float ActiveValue, bool&out ChangedShield)
    {
        FActiveEffect Shields;
        ActiveEffects.Find(GameplayTags::SpaceShip_ActiveEffect_ShieldsActivated, Shields);
        // Replace with Turn Paused / Turn Executing
        if (State == EShipMovementState::Moving || State == EShipMovementState::StoppedForPickup || State == EShipMovementState::Stopped)
        {
            QueuedActiveEffects.Add(GameplayTags::SpaceShip_ActiveEffect_ShieldsActivated, FActiveEffect(-1, ActiveValue, 1.0));
            ChangedShield = false;
            Print(f"Queued shield change");
            return ActiveValue != Shields.Value;
        }
        ActiveEffects.Add(GameplayTags::SpaceShip_ActiveEffect_ShieldsActivated, FActiveEffect(-1, ActiveValue, 1.0));
        ChangedShield = ActiveValue != Shields.Value;
        return ActiveValue == 1.0;
    }

    UFUNCTION(BlueprintPure)
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
            if (!ActiveEffects.Contains(GameplayTags::SpaceShip_ActiveEffect_Overload))
            {
                ActiveEffects.Add(GameplayTags::SpaceShip_ActiveEffect_Overload, FActiveEffect(3, 1.0, 1.0));
                OnOverheated.Broadcast(this);
            }
        }
        OnHeatChanged.Broadcast(CurrentHeat, MaxHeat);
    }

    UFUNCTION()
    void SetAfterburners(bool Active = true)
    {
        FStatModifier Afterburner = FStatModifier(GameplayTags::StatSource_ActiveEffect,
            GameplayTags::SpaceShip_Stat_Positive_MaxSpeed, EStatType::Multiplicative, 1.0);
        //1.0 -> +100% -> 2x increase

        //Just a usage example of checking active effects
        bool bAfterburnerIsActive = ActiveEffects.Contains(GameplayTags::SpaceShip_ActiveEffect_Afterburner);

        if(Active)
        {
            AddGlobalModifierStat(Afterburner);
            ActiveEffects.Add(GameplayTags::SpaceShip_ActiveEffect_Afterburner, FActiveEffect(-1, 1.0, 0));
            Print("Afteburners: ON");
            UpdateSpeedStat();
        }
        else
        {
            RemoveGlobalModifier(Afterburner);
            ActiveEffects.Remove(GameplayTags::SpaceShip_ActiveEffect_Afterburner);
            Print("Afteburners: OFF");
            UpdateSpeedStat();
        }
    }

    void UpdateSpeedStat()
    {
        float OldSpeed;
        CachedShipStats.Find(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed, OldSpeed);

        float NewSpeed = GetShipSpeed();

        if (OldSpeed != NewSpeed)
        {
            CachedShipStats.Add(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed, NewSpeed);
            OnSpeedChanged.Broadcast(NewSpeed);
        }

    }

    // Call once per WEGO turn resolution, after orders have been applied.
    UFUNCTION()
    void AdvanceTurn()
    {
        RecalculateShipStatsIfDirty();

        //Heat Dissipation
        if (!ActiveEffects.Contains(GameplayTags::SpaceShip_ActiveEffect_Overload))
        {
            float Dissipation = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_HeatDissipation, 0.0);
            //Print(f"Dissipation:{Dissipation}");
            CurrentHeat = Math::Max(0.0, CurrentHeat - Dissipation);
            OnHeatChanged.Broadcast(CurrentHeat, GetMaxHeat());
        }

        //Shield Regen
        float MaxShields = GetMaxShieldPoints();
        FActiveEffect Shields, LastShieldHit;
        ActiveEffects.Find(GameplayTags::SpaceShip_ActiveEffect_ShieldsActivated, Shields);
        bool HasLastHit = ActiveEffects.Find(GameplayTags::SpaceShip_ActiveEffect_LastShieldHit, LastShieldHit);
        if (CurrentShieldPoints < MaxShields && MaxShields > 0.0 && !HasLastHit)
        {
            float Regen = MaxShields * GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShieldRegenPercentPerTurn);
            CurrentShieldPoints = Math::Min(MaxShields, CurrentShieldPoints + Regen);
            OnShieldsChanged.Broadcast(CurrentShieldPoints, MaxShields, Regen);
        }

        //HP Regen
        //Inputting a negative value (for example a self healing weapon) will not overflow capacity
        UItemHull HullFragment = GetHullFragment();
        float Repair = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_DroidRepair);
        if (HullFragment != nullptr && HullFragment.CurrentDurability < HullFragment.GetMaximumDurability() && Repair > 0)
        {
            HullFragment.CurrentDurability = Math::Min(HullFragment.CurrentDurability + Repair, HullFragment.GetMaximumDurability());
            OnHPChanged.Broadcast(HullFragment.CurrentDurability, HullFragment.GetMaximumDurability(), Repair);
        }

        //ProcessQueuedActiveEffects();
        ProcessActiveEffects();

        if (bChangedLoadout)
        {
            bChangedLoadout = false;
        }
    }

    UFUNCTION()
    void ProcessActiveEffects()
    {
        ClearQueuedActiveEffects();
        TArray<FGameplayTag> ActiveEffectsKeys;
        ActiveEffects.GetKeys(ActiveEffectsKeys);
        TArray<FActiveEffect> ActiveEffectsValues;
        ActiveEffects.GetValues(ActiveEffectsValues);
        for (int32 i = 0; i < ActiveEffectsValues.Num(); i++)
        {
            FActiveEffect Temp = ActiveEffectsValues[i];
            float NewDuration = Temp.Duration <= -1 ? -1 : Temp.Duration - 1;
            float NewStacks = Math::Max(1.0, Temp.Stacks - 1.0);
            
            if (NewDuration == 0.0)
            { 
                ActiveEffects.Remove(ActiveEffectsKeys[i]); 
                Print(f"Removed {ActiveEffectsKeys[i]}");
                continue;
            }

            ActiveEffects.Add(ActiveEffectsKeys[i], FActiveEffect(NewDuration, Temp.Value, NewStacks));
            //Print(f"{ActiveEffectsKeys[i]}: Duration={NewDuration}, Value={Temp.Value}, Stacks={Temp.Stacks}");
        }
    }

    //How to use Queued Active Effects. If we want to use toggleable abilities mid turn, we want to take the example of
    //SetShieldsActive(). We add it to the queued active effects and process them at TurnUpdate and TurnPause
    //TurnUpdate:
    //  1. Temporarily Set our Movement State to a Paused State 
    //  2. For each Queued Active Effect -> Use the respective function
    //  3. Advance Turn
    //  4. Revert back to our previous Movement State 
    //  5. Path Stuff then Clear All Queued active effects
    // TurnPause:
    //  0. All other stuff
    //  1. For each Queued Active Effect -> Use the respective function
    //  2. Path Stuff then Clear All Queued active effects
    UFUNCTION()
    void ClearQueuedActiveEffects()
    {
        QueuedActiveEffects.Empty();
    }


    UFUNCTION()
    FDamageCalculationOutput ApplySelfDamage(FDamageSpec InDamage)
    {
        float ArmorNullification = GetActiveEffectValue(GameplayTags::SpaceShip_ActiveEffect_ArmorNullification, 1.0);
        FDamageCalculationInput Input;
        Input.SourceUnmitigatedDamage = InDamage.UnmitigatedDamage;
        Input.SourceShieldBypass = InDamage.ShieldBypass;
        Input.SourceGlobalDamageModifier = InDamage.GlobalDamageModifier;
        Input.TargetCurrentShields = CurrentShieldPoints;
        Input.bTargetHasShieldsActive = GetActiveEffectValue(GameplayTags::SpaceShip_ActiveEffect_ShieldsActivated) == 1.0;
        Input.TargetShieldDamageBlock = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShieldGeneratorDamageBlock, 0.0);
        Input.TargetShipDamageResistance = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_ShipDamageResistance, 1.0) * ArmorNullification;
        Input.TargetTypeSpecificResistance = GetResistanceForDamageType(InDamage.DamageType);
        Input.bTargetIsInvulnerable = GetActiveEffectValue(GameplayTags::SpaceShip_ActiveEffect_Invulnerability) == 1.0;

        FDamageCalculationOutput Output = GameLogic::CalculateDamage(Input);

        if (Output.ShieldDamage > 0.0)
            ApplyShieldDamage(Output.ShieldDamage);

        if (Output.HullDamage > 0.0)
            ApplyHullDamage(Output.HullDamage);

        //Some weapons might have different energy buildup
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

        //TODO Check for specific environmental resistances to GameplayTags::DamageType_Environmental_Asteroid, 
        //GameplayTags::DamageType_Environmental_Star, and any equipment that could modifiy those resistances

        return 1.0; // DamageType_Chemical / DamageType_Generic - flat armor only
    }
    

    UFUNCTION()
        bool FireWeaponAt(FGameplayTag WeaponSlotTag, UShipStateComponent Target, float&out TotalDamage=0.0)
    {
        UItemWeapon Weapon = GetWeaponFragment(WeaponSlotTag);
        //TODO: Implement Max range check
        if (Target == nullptr || !EquipmentSlots.Contains(WeaponSlotTag) || Weapon == nullptr || !Weapon.IsOperational())
            return false;

        float Accuracy = GetShipStat(GameplayTags::SpaceShip_Stat_Positive_Accuracy, 0.0);
        float HeatModifier = 1 / GetShipStat(GameplayTags::SpaceShip_Stat_Positive_HeatEfficiency);

        float EffectiveMaxDamage = GetEffectiveWeaponMaxDamage(WeaponSlotTag);

        FDamageSpec Damage = GameLogic::CreateDamageSpec(Target, Weapon.DamageType, Weapon.MinDamage, EffectiveMaxDamage, Accuracy, Weapon.ShieldBypass);
        FDamageCalculationOutput Output = Target.ApplySelfDamage(Damage);

        AddHeat(Weapon.HeatUse * HeatModifier); // firing costs the shooter heat too
        TotalDamage = Math::RoundToFloat(Output.HullDamage + Output.ShieldDamage);
        return true;
    }

    UFUNCTION()
    float GetFactionDamage()
    {
        return GetShipStat(GetFactionTargetTag(Faction), 0.0);
    }

    UFUNCTION()
    bool FireProjectileWeapon(FGameplayTag WeaponSlotTag, USceneComponent HomingTarget, FProjectileDamageSpec&out Damage)
    {
        UItemWeapon Weapon = GetWeaponFragment(WeaponSlotTag);
        if (HomingTarget == nullptr || !EquipmentSlots.Contains(WeaponSlotTag) || Weapon == nullptr || !Weapon.IsOperational())
            return false;

        Damage = FProjectileDamageSpec(
                    HomingTarget, 
                    Weapon.DamageType, 
                    WeaponSlotTag,
                    Weapon.MinDamage, 
                    GetEffectiveWeaponMaxDamage(WeaponSlotTag), 
                    GetShipStat(GameplayTags::SpaceShip_Stat_Positive_Accuracy, 0.0),
                    Weapon.ShieldBypass);

        float HeatModifier = 1 / GetShipStat(GameplayTags::SpaceShip_Stat_Positive_HeatEfficiency);
        AddHeat(Weapon.HeatUse * HeatModifier); // firing costs the shooter heat too

        return true;
    }

    //TODO: Create a map that maps Faction->Damage and DamageType->Damage
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

    UPROPERTY(EditAnywhere, Category = "Debug|Self Test")
    UItemDefinition TestRadarDefinition;

    UPROPERTY(EditAnywhere, Category = "Debug|Self Test")
    UItemDefinition TestDroidDefinition;

    UFUNCTION()
    void RunSelfTest()
    {
        FGameItem Hull = InstantiateItem(TestHullDefinition);
        UItemHull Fragment = Cast<UItemHull>(UGameUtility::GetItemFragment(Hull.Fragments, UItemHull));
        Hull.Mass = Math::RoundToInt(Fragment.GetHullMass());
        float Speed1 = Fragment.GetItemStat(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed);
        float Dur1 = Fragment.GetItemStat(GameplayTags::SpaceShip_Stat_Positive_MaximumDurability);

        //Fragment.AddModifier(GameplayTags::StatSource_Upgrade, GameplayTags::SpaceShip_Stat_Positive_MaxSpeed, EStatType::Multiplicative,0.31);
        Fragment.AddModifier(GameplayTags::StatSource_Micromodule1, GameplayTags::SpaceShip_Stat_Positive_MaximumDurability, EStatType::Multiplicative, 0.2);
        Fragment.RecalculateStats();
        float Speed2 = Fragment.GetItemStat(GameplayTags::SpaceShip_Stat_Positive_MaxSpeed);
        float Dur2 = Fragment.GetItemStat(GameplayTags::SpaceShip_Stat_Positive_MaximumDurability);
        //Print(f"MaxDur:{Dur1}->{Dur2}\nCurrentDur:{Fragment.CurrentDurability}");

        //AddGlobalModifier(GameplayTags::StatSource_Artifact, GameplayTags::SpaceShip_Stat_Positive_DamageKinetic, EStatType::Additive, 10);
        
        SwapItem(GameplayTags::SpaceShip_Equipment_Hull, InstantiateItem(TestHullDefinition));
    
        if (TestWeaponDefinition != nullptr)
        {
            EquipItem(GameplayTags::SpaceShip_Equipment_Weapon_01, InstantiateItem(TestWeaponDefinition));
            EquipItem(GameplayTags::SpaceShip_Equipment_Weapon_02, InstantiateItem(TestWeaponDefinition));
            EquipItem(GameplayTags::SpaceShip_Equipment_Weapon_03, InstantiateItem(TestWeaponDefinition));
            EquipItem(GameplayTags::SpaceShip_Equipment_Weapon_04, InstantiateItem(TestWeaponDefinition));
            EquipItem(GameplayTags::SpaceShip_Equipment_Weapon_05, InstantiateItem(TestWeaponDefinition));
        }
        //FGameItem BrokenWeapon;
        UItemWeapon BrokenWeapon = GetWeaponFragment(GameplayTags::SpaceShip_Equipment_Weapon_05);
        BrokenWeapon.CurrentDurability = 0.0;


        for (int32 i = 0; i < 5; i++)
        {
            WeaponOrders[i].WeaponState = EWeaponState::Equipped;
            UItemWeapon weapon = GetWeaponFragment(GameLogic::GetWeaponSlot(i));
            weapon.AddModifier(GameplayTags::StatSource_ScriptedEffect, GameplayTags::SpaceShip_Stat_Positive_Weapon_Range,
            EStatType::Additive, 40.0 * i);
            weapon.RecalculateStats();
        } //6 for normal ships, 10 for stations

        WeaponOrders[4].WeaponState = EWeaponState::Broken; //must update dynamically

        if (TestShieldGeneratorDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_ShieldGenerator, InstantiateItem(TestShieldGeneratorDefinition));

        if (TestFuelTankDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_FuelTank, InstantiateItem(TestFuelTankDefinition));

        if (TestTractorBeamDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_TractorBeam, InstantiateItem(TestTractorBeamDefinition));
        
        if (TestRadarDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_Radar, InstantiateItem(TestRadarDefinition));

        if (TestRadarDefinition != nullptr)
            EquipItem(GameplayTags::SpaceShip_Equipment_Droid, InstantiateItem(TestDroidDefinition));

        ActiveEffects.Add(GameplayTags::SpaceShip_ActiveEffect_ShieldsActivated, FActiveEffect(-1, 1.0, 1.0));
        FStatAttribute Accuracy = FStatAttribute(GameplayTags::SpaceShip_Stat_Positive_Accuracy, 0.0);
        CharacterStats.Add(Accuracy);
        CharacterStats.Add(FStatAttribute(GameplayTags::SpaceShip_Stat_Positive_HeatDissipation, 15));


        //AddGlobalModifier(GameplayTags::StatSource_Artifact, GameplayTags::SpaceShip_Stat_Negative_ShipMass, EStatType::Multiplicative, 3.0);
        //SetAfterburners(true);
        bChangedLoadout = true;
        RecalculateShipStats();

        //RemoveAllGlobalModifiersByStat(GameplayTags::SpaceShip_Stat_Negative_ShipMass);
        //RecalculateShipStats();
        CurrentShieldPoints = GetMaxShieldPoints();

        FTractorBeamProperties TB = GetTractorBeamProps();
        //Print(TB.ToString());

        
        TArray<FGameplayTag> Stats;
        CachedShipStats.GetKeys(Stats);
        for (FGameplayTag Stat : Stats)
        {
            //Print(f"Stat:{Stat}={CachedShipStats[Stat]}", 20);
        }
        for (FStatModifier Stat : GlobalModifiers)
        {
            //Print(f"Stat:{Stat.StatTag}={Stat.Value}", 20);
        }

        //Print(f"{GameplayTags::SpaceShip_Stat_Positive_MaxSpeed} - {CachedShipStats[GameplayTags::SpaceShip_Stat_Positive_MaxSpeed]}", 20);

        
        
        float CurrentMass = GetShipStat(GameplayTags::SpaceShip_Stat_Negative_ShipMass);
        float MaxHull = GetMaxHullPoints();
        float HP = GetCurrentHullPoints();
        float MaxShields = GetMaxShieldPoints();
        float MaxHeat = GetMaxHeat();
        float Speed = GetShipSpeed();

        //Print(f"Mass: {CurrentMass}", 20);
        //Print(f"HP: {HP}/{MaxHull}", 20);
        //Print(f"SP: {CurrentShieldPoints}/{MaxShields}", 20);
        //Print(f"Speed: {Speed}", 20);
        //Print("-------------\nOUR VALUES\n------------", 20);

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
            float Damage;
            FireWeaponAt(GameplayTags::SpaceShip_Equipment_Weapon_01, DummyTarget, Damage);
            
            float D_MaxHull = DummyTarget.GetMaxHullPoints();
            float D_HP = DummyTarget.GetCurrentHullPoints();
            float D_MaxShields = DummyTarget.GetMaxShieldPoints();
            float D_MaxHeat = DummyTarget.GetMaxHeat();

            //Print(f"HP: {D_HP}/{D_MaxHull}", 20);
            //Print(f"SP: {DummyTarget.CurrentShieldPoints}/{D_MaxShields}", 20);
            //Print(f"Heat: {DummyTarget.CurrentHeat}/{D_MaxHeat}", 20);
            //Print(f"Damaged target for: {Damage}", 20);
            //Print("-------------\nDUMMY VALUES\n------------", 20);
            //
            //Print(f"My Heat: {CurrentHeat}/{MaxHeat}", 20);
        }
    }

    UFUNCTION()
    void Init()
    {

    }

}
