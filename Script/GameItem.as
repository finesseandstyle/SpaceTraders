/*From Item.h
UCLASS(Abstract, EditInlineNew, CollapseCategories)
class SPACETRADERS_API UItemFragment : public UObject {GENERATED_BODY()};

UCLASS(BlueprintType)
class SPACETRADERS_API UItemDefinition : public UDataAsset
{
	GENERATED_BODY()

public:
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, meta = (MultiLine="true"))
	FText Name;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, meta = (MultiLine="true"))
	FText Description;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	FGameplayTag ItemType;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	int32 BasePrice = 0; //A base price of -1 would signal that the item has no price to display

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	TSoftObjectPtr<UTexture2D> Icon;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	TSoftClassPtr<UObject> Class;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	TSoftObjectPtr<UStaticMesh> StaticMesh;

	//If true, items with the same ItemKey will stack
	//Container items should never stack, instead they work a bit differently
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	bool IsStackable = false;

	//Mass of an item equals Mass * Weight Multiplier if it's a stackable item
    //All equipment is non stackable, meaning its Item Mass is always equal to the Mass value 
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	float WeightMultiplier = 1.f;
	
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Instanced, Category = "Fragments", Meta = (EditFixedOrder))
	TArray<UItemFragment*> Fragments;
	
    //the same function also exists on UGameUitility
	UFUNCTION(BlueprintCallable, meta = (DeterminesOutputType = "FragmentType"))
	const UItemFragment* GetFragment(const TSubclassOf<UItemFragment>& FragmentType) const
	{
		for (const auto Fragment : Fragments)
		{
			if (Fragment && Fragment->IsA(FragmentType))
			{
				return Fragment;
			}
		}

		return nullptr;
	}
};
*/

enum EMicromoduleType
{
	Blue,   //Level 3
	Yellow, //Level 2
	Red,    //Level 1
	Special //Level 0, unique, one time only
};

struct FGameItem {
    UPROPERTY() UItemDefinition ItemDefinition;
    UPROPERTY() int Mass = 1; //Stacks or Space occupied
    UPROPERTY() int Value = 0;
    UPROPERTY() FGameplayTag Origin; //which race / faction produced it
    UPROPERTY() FGameplayTag Manufacturer; //optional
    UPROPERTY() TArray<UItemFragment> Fragments;

    FGameItem(UItemDefinition InDefinition, int InMass, int InValue, FGameplayTag InOrigin, 
        FGameplayTag InManufacturer = FGameplayTag(), const TArray<UItemFragment>& InFragments = TArray<UItemFragment>())
    {
        ItemDefinition = InDefinition;
        Mass = InMass;
        Value = InValue;
        Origin = InOrigin;
        Manufacturer = InManufacturer;
        Fragments = InFragments;
    }

    // --- NEW ---------------------------------------------------------------
    bool IsValid() const
    {
        return ItemDefinition != nullptr;
    }

    // Per Item.h: stackable items (trade goods) mass Mass * WeightMultiplier,
    // non-stackable items (equipment) mass just Mass. Hull items don't use
    // this at all - see UItemHull::GetHullMass().
    float GetItemMass() const
    {
        if (!IsValid())
            return 0.0;

        return ItemDefinition.IsStackable ? (Mass * ItemDefinition.WeightMultiplier) : float(Mass);
    }

    // Finds the fragment that actually makes this item functional equipment
    // (weapon/hull/shield generator/etc). Plain trade goods won't have one.
    UItemEquipment GetEquipmentFragment() const
    {
        for (const auto Fragment : Fragments)
        {
            UItemEquipment AsEquipment = Cast<UItemEquipment>(Fragment);
            if (AsEquipment != nullptr)
                return AsEquipment;
        }
        return nullptr;
    }
    // -------------------------------------------------------------------
};

class UItemEquipment : UItemFragment
{
    //Random number, used as a seed for upgrading or comparing IDs 
    UPROPERTY() int MagicNumber = Math::Rand();
    UPROPERTY() float CurrentDurability = 100.0;
    //reliability doesn't need an attribute as its maximum value is only determined by Origin/Manufacturer
    UPROPERTY() float Reliability = 100.0; //affects how fast items's durability gets degraded (non-hull)
    UPROPERTY() TArray<FStatAttribute> Stats;
    UPROPERTY() TArray<FStatModifier> Modifiers; //only modify our own native stats
    UPROPERTY() TArray<FStatModifier> GlobalModifiers; //can modify other stats from other equipment types
    UPROPERTY() uint8 TechLevel = 1; //1 to 8

    bool IsOperational() const { return CurrentDurability > 0.0; }

    // --- NEW -----------------------------------------------------------
    // Smart recalculation: each FStatAttribute already carries its own
    // bDirty flag. Instead of recomputing every stat whenever anything
    // changes, we only flip bDirty on the specific stat tag(s) a modifier
    // change actually affects, and RecalculateStats() skips anything that's
    // still clean. Called from the ship's aggregation pass every time it
    // runs, so it needs to be cheap when nothing changed - and it is, since
    // clean stats cost one branch each.
    void RecalculateStats()
    {
        for (auto& Stat : Stats)
        {
            if (!Stat.bDirty)
                continue;

            Stat.Value = GameLogic::ApplyModifiers(Stat.BaseValue, Stat.StatTag, Modifiers);
            Stat.bDirty = false;

            if (Stat.StatTag == GameplayTags::SpaceShip_Stat_Positive_MaximumDurability)
            {
                CurrentDurability = Math::Min(CurrentDurability, Stat.Value);
            }
        }
    }

    float GetMaximumDurability() const
    {
        return GetStatValue(GameplayTags::SpaceShip_Stat_Positive_MaximumDurability);
    }

    float GetStatValue(FGameplayTag StatTag) const
    {
        for (const auto& Stat : Stats)
        {
            if (Stat.StatTag == StatTag)
                return Stat.Value;
        }
        return 0.0;
    }

    void MarkStatDirty(FGameplayTag StatTag)
    {
        for (auto& Stat : Stats)
        {
            if (Stat.StatTag == StatTag)
                Stat.bDirty = true;
        }
    }

    // Force a full recompute - mainly for right after instantiation, since a
    // freshly duplicated FStatAttribute may have been saved with bDirty=false
    // on the template asset and would otherwise wrongly short-circuit.
    void MarkAllStatsDirty()
    {
        for (auto& Stat : Stats)
            Stat.bDirty = true;
    }

    void AddModifier(FStatModifier NewModifier)
    {
        Modifiers.Add(NewModifier);
        MarkStatDirty(NewModifier.StatTag); // only the stat(s) this modifier targets need recompute
    }

    void AddModifier(FGameplayTag SourceType, FGameplayTag StatTag, EStatType Type, float Value = 0.0)
    {
        FStatModifier NewModifier;
        NewModifier.SourceType = SourceType;
        NewModifier.StatTag = StatTag;
        NewModifier.Type = Type;
        NewModifier.Value = Value;
        Modifiers.Add(NewModifier);
        MarkStatDirty(NewModifier.StatTag); // only the stat(s) this modifier targets need recompute
    }
    // ---------------------------------------------------------------------

    void RemoveModifiersFromSource(FGameplayTag SourceType)
    {
        for (int32 i = Modifiers.Num() - 1; i >= 0; i--)
        {
            if (Modifiers[i].SourceType == SourceType)
            {
                MarkStatDirty(Modifiers[i].StatTag); // NEW: dirty exactly what we're about to remove
                Modifiers.RemoveAt(i);
            }
        }
    }

    void RemoveUpgrades() {
        RemoveModifiersFromSource(GameplayTags::StatSource_Upgrade); // NEW: reuses the generalized version above
    }

    void RemoveMicromodules() {
        RemoveModifiersFromSource(GameplayTags::StatSource_Micromodule1);
        RemoveModifiersFromSource(GameplayTags::StatSource_Micromodule2);
    }
}

//essentially a Diablo style rune that can be socketed into a compatible item
class UMicromodule : UItemFragment
{
    //List of races and equipment slots that the micromodule can be installed into
	//The actual stat effects can be part of a lookup data table that get added when adding the micromodule.
    //The first slot will add stat modifiers from the Source = Micromodule1, 2nd for Micromodule2
	//For example a micromodule that can only be installed into human space ships has these 2:
	//Races.Coalition.Human | Equipment.Hull
	//A micromodule that can be installed into any equipment slot and to any Coalition race has the following tags:
	//Races.Coalition | Equipment
	//Micromodule that can be installed into any equipment except hulls.
	//Equipment.Weapon | Equipment.Engine | Equipment.FuelTank | Equipment.Droid | etc.
	//This would probably better fit in a seperate data table
    //The actual effects 
    FGameplayTagContainer Compatibility;
    EMicromoduleType Type;
}

//Both base values for min and max damages are defined table values for each tech level.
//For example Rocket Launcher:
//Maloq Race Reliability = 70, TechLevel 1, Damage: 10-12, Range: 450, MissileCapacity = 3
//Human Race Reliability = 85, TechLevel 8, Damage: 20-25, Range: 550, MissileCapacity = 6


class UItemWeapon : UItemEquipment
{
    UPROPERTY() FGameplayTag WeaponSize = GameplayTags::WeaponSize_Medium; //Small, Medium, Large

    //Min Range, Max Range, Max damage is already part of the ItemEquipment's Stats

    //All of these 5 values can be instead read from a Data Table or Asset, aren't expected to be modifiable anyway.
    UPROPERTY() float MinDamage = 10; //Always related to the item's tech leve
    UPROPERTY() float HeatUse = 5.0;
	UPROPERTY() float MiningEfficiency  = 0.5;
	UPROPERTY() float ShieldBypass = 0.0;
    
    UPROPERTY() TArray<UOnHitEffect> OnHitEffects; //should we use array of object for this?
    UPROPERTY() FGameplayTag DamageType = GameplayTags::DamageType_Kinetic; //explosive, energetic, chemical
}

class UItemHull : UItemEquipment
{
	UPROPERTY() FGameplayTagContainer OpenSlots; //Spaceship_Equipment tags

	float GetHullSize() { 
        return GetStatValue(GameplayTags::SpaceShip_Stat_Positive_CargoCapacity) + 
               GetStatValue(GameplayTags::SpaceShip_Stat_Positive_EquipmentCapacity); 
    }
    float GetHullMass() { return Math::RoundToFloat(GetHullSize() * (0.6 + 0.03 * (TechLevel - 1))); }
};

class UItemFuelTank : UItemEquipment
{
    UPROPERTY() float CurrentFuel = 20;
}


class UOnHitEffect : UObject //not sure if it should extend uobject
{
    //describes what fx to use, on hit behavior (AoE, chain lighting, single target and their related params), 
    //damage if it exists, type of effect(s) - slowdown, extra damage, equipment block, item durability damage, DoT, etc.
}

//Modifiable stats like MaxHealth, MaxShieldPoints, MaxDamage, WeaponRange, RadarRange, ShipSpeed

struct FStatAttribute
{
    UPROPERTY() FGameplayTag StatTag;
    UPROPERTY() float BaseValue = 100.0;
    UPROPERTY() float Value = 100.0; //Base Value + Any Upgrades + Any Micromodule Effects
    UPROPERTY() bool bDirty = false; //we only flag as dirty when we modify the stat, for example upgrade it, add a micromodule, etc

    FStatAttribute(FGameplayTag InStatTag, const float InBaseValue)
    {
        StatTag = InStatTag;
        BaseValue = InBaseValue;
        Value = InBaseValue;
        bDirty = false;
    }
};

struct FRangedStatAttribute
{
    FStatAttribute MaxValueStat;
    float CurrentValue = 100.0;
};

enum EStatType
{
    Additive,
    Multiplicative,
    Override // Any occurance of override ignores every other stat modifier
}

struct FStatModifier
{
    //Purely for book
    UPROPERTY() FGameplayTag SourceType; //Upgrade, Micromodule1/2, Acrine, Artifact, Active Effects like Stimulants, etc.
    UPROPERTY() FGameplayTag StatTag; //Engine Speed, Radar Range, Weapon Max Damage, the actual stat type
    UPROPERTY() EStatType Type;
    UPROPERTY() float Value = 0.0;

    bool opEquals(const FStatModifier& Other) const
    {
        return SourceType == Other.SourceType && StatTag == Other.StatTag && Type == Other.Type && Value==Other.Value;
    }

    FStatModifier(FGameplayTag InSource, FGameplayTag InTag, EStatType InType, const float InValue)
    {
        SourceType = InSource;
        StatTag = InTag;
        Type = InType;
        Value = InValue;
    }
}
