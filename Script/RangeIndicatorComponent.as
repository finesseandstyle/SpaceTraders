const float BaseRotationSpeed = 40; 
const float DashRatio = 0.5;
const float MinSections = 24.0;

// A segmented ring material on a plane mesh to communicate the interaction 
//range of an ability or equipment, like a radar, weapon or tractor beam
//Use SetRingMaterial with the default plane mesh, set a color and radius
class URangeIndicatorComponent : UStaticMeshComponent
{
    UPROPERTY() FLinearColor BaseColor = FLinearColor(0.0, 0.0, 1.0, 1.0); // Bright Cyan
    UPROPERTY() FLinearColor OutlineColor = FLinearColor::Black;

    private UMaterialInstanceDynamic DynamicMaterial;
    private float WorldRadius;

    //It's so that the ring doesn't roll with the ship
    default SetAbsolute(false, true, true);
    default SetVisibility(false);
    default SetCastShadow(false);

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

    // Call at runtime when changing interaction range
    UFUNCTION(BlueprintCallable, Category = "Range Ring")
    void SetRadius(float NewWorldRadius)
    {
        WorldRadius = NewWorldRadius;

        if (WorldRadius <= 0) return;

        // 45.0 local radius provides safety margin on 100x100 quad to prevent edge clipping
        const float TargetLocalRadius = 45.0;
        float ScaleFactor = WorldRadius / TargetLocalRadius;
        
        int NumSegments = Math::Max(Math::RoundToInt(Math::Sqrt(WorldRadius) * 0.75), Math::RoundToInt(MinSections));
        float Speed = BaseRotationSpeed / WorldRadius; //preserving angular velocity
        // Scale component plane
        SetWorldScale3D(FVector(ScaleFactor, ScaleFactor, 1.0));
        

        // Sync parameters to shader
        if (DynamicMaterial != nullptr)
        {
            DynamicMaterial.SetScalarParameterValue(n"TargetRadius", TargetLocalRadius);
            DynamicMaterial.SetScalarParameterValue(n"NumSegments", NumSegments);
            DynamicMaterial.SetScalarParameterValue(n"DashRatio", DashRatio);
            DynamicMaterial.SetVectorParameterValue(n"CoreColor", BaseColor);
            DynamicMaterial.SetVectorParameterValue(n"OutlineColor", OutlineColor);
            DynamicMaterial.SetScalarParameterValue(n"RotationSpeed", Speed);
        }
    }

    UFUNCTION()
    void SetIndicatorVisibility(bool bNewVisibility)
    {
        SetVisibility(WorldRadius > 0 ? bNewVisibility : false);
    }
};