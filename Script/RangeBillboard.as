class URangeIndicatorComponent : UStaticMeshComponent
{
    // Interaction radius in World Units
    UPROPERTY(EditAnywhere, Category = "Range Ring")
    float WorldRadius = 1000.0;

    // Ratio of dash length to gap length (0.5 = 50% line, 50% gap)
    UPROPERTY(EditAnywhere, Category = "Range Ring", meta = (ClampMin = "0.0", ClampMax = "1.0"))
    float DashRatio = 0.5;

    UPROPERTY() float BaseRotationSpeed = 40;

    // Core stroke color (Bright)
    UPROPERTY(EditAnywhere, Category = "Range Ring")
    FLinearColor CoreColor = FLinearColor(0.0, 0.0, 1.0, 1.0); // Bright Cyan

    // Outline stroke color (Dark for contrast)
    UPROPERTY(EditAnywhere, Category = "Range Ring")
    FLinearColor OutlineColor = FLinearColor::Black;

    const float MinSections = 12.0;
    private UMaterialInstanceDynamic DynamicMaterial;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        SetAbsolute(false, true, false);
        UpdateRing();
    }

    UFUNCTION()
    void SetRingMaterial(UStaticMesh Plane, UMaterialInterface BaseMaterial)
    {
        // Create DMI directly via primitive component helper
        if (Plane != nullptr && BaseMaterial != nullptr)
        {
            SetStaticMesh(Plane);
            DynamicMaterial = CreateDynamicMaterialInstance(0, BaseMaterial);
            SetCollisionEnabled(ECollisionEnabled::NoCollision);
            SetCastShadow(false);
        }
    }

    UFUNCTION(BlueprintCallable, Category = "Range Ring")
    void UpdateRing()
    {
        // 45.0 local radius provides safety margin on 100x100 quad to prevent edge clipping
        const float TargetLocalRadius = 42.0;
        float ScaleFactor = WorldRadius / TargetLocalRadius;
        
        int NumSegments = Math::Max(Math::RoundToInt(WorldRadius / 40.0), Math::RoundToInt(MinSections));
        float Speed = BaseRotationSpeed / WorldRadius; //preserving angular velocity
        // Scale component plane
        SetWorldScale3D(FVector(ScaleFactor, ScaleFactor, 1.0));

        // Sync parameters to shader
        if (DynamicMaterial != nullptr)
        {
            DynamicMaterial.SetScalarParameterValue(n"TargetRadius", TargetLocalRadius);
            DynamicMaterial.SetScalarParameterValue(n"NumSegments", NumSegments);
            DynamicMaterial.SetScalarParameterValue(n"DashRatio", DashRatio);
            DynamicMaterial.SetVectorParameterValue(n"CoreColor", CoreColor);
            DynamicMaterial.SetVectorParameterValue(n"OutlineColor", OutlineColor);
            DynamicMaterial.SetScalarParameterValue(n"RotationSpeed", Speed);
        }
    }

    // Call at runtime when changing interaction range
    UFUNCTION(BlueprintCallable, Category = "Range Ring")
    void SetRadius(float NewRadius)
    {
        WorldRadius = NewRadius / 2;
        Print(f"{WorldRadius}");
        UpdateRing();
    }
};