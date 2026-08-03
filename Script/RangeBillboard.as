// Component attached to ships to render an adaptive, 3-layer range indicator.
class URangeBillboardComponent : UMaterialBillboardComponent
{
    // ========================================================================
    // Configuration & Materials
    // ========================================================================

    UPROPERTY(EditAnywhere, Category = "Range Indicator")
    UMaterialInterface MainMaterial;

    UPROPERTY(EditAnywhere, Category = "Range Indicator")
    UMaterialInterface StrokeMaterial;

    UPROPERTY(EditAnywhere, Category = "Range Indicator")
    float Sharpness = 1.0;

    // Default starting radius (Diameter = Radius * 2)
    UPROPERTY(EditAnywhere, Category = "Range Indicator")
    float DefaultRadius = 500.0;

    // ========================================================================
    // Constants
    // ========================================================================

    const float BaseThickness = 2.0;
    const float MinSections = 24.0;
    const float BaseRotationSpeed = 150;
    const float StrokeThickness = 4.0;

    // ========================================================================
    // Transient DMI Cache
    // ========================================================================

    private UMaterialInstanceDynamic MainDMI;
    private UMaterialInstanceDynamic InnerStrokeDMI;
    private UMaterialInstanceDynamic OuterStrokeDMI;

    // ========================================================================
    // Component Lifecycle
    // ========================================================================

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        InitializeBillboardElements();
        UpdateRadius(DefaultRadius);
    }

    // Instantiates DMIs and initializes the 3 sprite elements on the billboard
    private void InitializeBillboardElements()
    {
        if (MainMaterial == nullptr || StrokeMaterial == nullptr)
        {
            Print("URangeBillboardComponent: Missing MainMaterial or StrokeMaterial!");
            return;
        }

        // Create Dynamic Material Instances
        MainDMI = CreateDynamicMaterialInstance(0, MainMaterial);
        InnerStrokeDMI = CreateDynamicMaterialInstance(0, StrokeMaterial);
        OuterStrokeDMI = CreateDynamicMaterialInstance(0, StrokeMaterial);

        SetElements(GetNewElements(DefaultRadius));
    }

    private TArray<FMaterialSpriteElement> GetNewElements(float NewRadius)
    {
        TArray<FMaterialSpriteElement> NewElements = TArray<FMaterialSpriteElement>();

        FMaterialSpriteElement MainElement;
        MainElement.Material = MainDMI;
        MainElement.BaseSizeX = NewRadius;
        MainElement.BaseSizeY = NewRadius;
        MainElement.bSizeIsInScreenSpace = false;
        NewElements.Add(MainElement);

        // 1: Inner Stroke (Base Size 996 x 996 -> 4 units smaller in diameter)
        FMaterialSpriteElement InnerElement;
        InnerElement.Material = InnerStrokeDMI;
        InnerElement.BaseSizeX = NewRadius - StrokeThickness;
        InnerElement.BaseSizeY = NewRadius - StrokeThickness;
        InnerElement.bSizeIsInScreenSpace = false;
        NewElements.Add(InnerElement);

        // 2: Outer Stroke (Base Size 1004 x 1004 -> 4 units larger in diameter)
        FMaterialSpriteElement OuterElement;
        OuterElement.Material = OuterStrokeDMI;
        OuterElement.BaseSizeX = NewRadius + StrokeThickness;
        OuterElement.BaseSizeY = NewRadius + StrokeThickness;
        OuterElement.bSizeIsInScreenSpace = false;
        NewElements.Add(OuterElement);

        return NewElements;
    }

    // ========================================================================
    // Radius & Shader Update Logic
    // ========================================================================

    UFUNCTION(BlueprintCallable, Category = "Range Indicator")
    void UpdateRadius(float NewRadius)
    {
        if (NewRadius <= 0.0 || Elements.Num() < 3)
            return;

        // --------------------------------------------------------------------
        // 1. Update Base Sizes for Sprite Elements
        // --------------------------------------------------------------------

        TArray<FMaterialSpriteElement> NewElements = GetNewElements(NewRadius);

        // Index 0: Main

        // --------------------------------------------------------------------
        // 2. Update DMI Parameters for All 3 Elements
        // --------------------------------------------------------------------
        ApplyDMIParameters(MainDMI, NewRadius);
        ApplyDMIParameters(InnerStrokeDMI, NewRadius);
        ApplyDMIParameters(OuterStrokeDMI, NewRadius);
        SetElements(NewElements);

        // Refresh render bounds in the scene proxy
        MarkRenderStateDirty();
        ToggleVisibility();
        ToggleVisibility();
    }

    // Helper to calculate and set material parameters per element DMI
    private void ApplyDMIParameters(UMaterialInstanceDynamic TargetDMI, float NewRadius)
    {
        if (TargetDMI == nullptr)
            return;

        // Math Calculations
        float Thickness = BaseThickness / NewRadius;
        float InnerRadius = 0.5 - Thickness;

        // Dynamic Section count: scaled with radius, clamped to MinSections
        float RawSections = NewRadius / 40.0;
        float Sections = Math::RoundToFloat(Math::Max(RawSections, MinSections));

        // Anti-aliasing relative to visual resolution & sharpness
        float AntiAlias = NewRadius * Sharpness;

        // Constant Angular Velocity: Speed = BaseRotationSpeed / Diagonal Size
        float Diagonal = Math::Sqrt(NewRadius * NewRadius * 2);
        float RotationSpeed = BaseRotationSpeed / Diagonal;

        // Set Scalar Parameters on Material
        TargetDMI.SetScalarParameterValue(n"Thickness", Thickness);
        TargetDMI.SetScalarParameterValue(n"InnerRadius", InnerRadius);
        TargetDMI.SetScalarParameterValue(n"Sections", Sections);
        TargetDMI.SetScalarParameterValue(n"AntiAliasSegments", AntiAlias);
        TargetDMI.SetScalarParameterValue(n"AntiAliasCircle", AntiAlias);
        TargetDMI.SetScalarParameterValue(n"RotationSpeed", RotationSpeed);
    }
}