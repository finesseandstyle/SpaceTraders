struct FGameItem {
    UPROPERTY() UItemDefinition ItemDefinition;
    UPROPERTY() int Stacks = 1;
    UPROPERTY() int Value = 0;
    UPROPERTY() FGameplayTag Origin;
    UPROPERTY() FGameplayTag Manufacturer; 
    UPROPERTY() TArray<UItemFragment> Fragments;
}