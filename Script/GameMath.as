namespace GameMath
{
    UFUNCTION()
    float GetCursorAngle() 
    {
        return 1;
    }

    // Returns an FVector2D where X and Y are either -1, 0, or 1 representing the scroll direction based on screen edges.
    UFUNCTION()
    FVector2D GetEdgeScrollDirection (FVector2D MousePos, float ScrollPixels, FVector2D ViewportSize)
    {
        FVector2D ScrollDir = FVector2D::ZeroVector;

        if (MousePos.X <= ScrollPixels)
        {
            ScrollDir.X = -1.0f; // Left Edge
        }
        else if (MousePos.X >= (ViewportSize.X - ScrollPixels))
        {
            ScrollDir.X = 1.0f;  // Right Edge
        }

        if (MousePos.Y <= ScrollPixels)
        {
            ScrollDir.Y = 1.0f; // Top Edge
        }
        else if (MousePos.Y >= (ViewportSize.Y - ScrollPixels))
        {
            ScrollDir.Y = -1.0f;  // Bottom Edge
        }

        return ScrollDir;
    }
    
    //Mathematically correct implementation that doesn't return negative values
    UFUNCTION()
    int Modulo(int A, int B)
    {
        return ((A % B) + B) % B;
    }

    //Mathematically correct implementation that doesn't return negative values
    UFUNCTION()
    float FModulo(float A, float B)
    {
        return ((A % B) + B) % B;
    }

    // Angle of a screen point relative to the center in degrees (0 to 360) where 0° is straight UP (12 o'clock), increments clockwise
    UFUNCTION()
    float GetScreenPositionAngle(FVector2D ScreenPos, FVector2D ViewportSize)
    {
        FVector2D HalfViewport = ViewportSize * 0.5f;
        float AngleDegrees = Math::RadiansToDegrees(Math::Atan2(ScreenPos.X - HalfViewport.X, -(ScreenPos.Y - HalfViewport.Y))) + 360;

        return AngleDegrees % 360;
    }

    UFUNCTION()
    FVector ExtendPath (FVector StartLocation, FVector EndLocation, float Extension)
    {
        return (EndLocation - StartLocation).GetSafeNormal() * Extension + StartLocation;
    }

    //Returns the mouse location of the playfield ignoring every game object in the way
    UFUNCTION()
    bool GetPlayfieldLocation (APlayerController PlayerController, FVector&out PlayfieldLocation)
    {
        FHitResult HitResult;
        PlayerController.GetHitResultUnderCursorByChannel(ETraceTypeQuery::Camera, false, HitResult);
        PlayfieldLocation = HitResult.Location;
        return HitResult.bBlockingHit;
    }

    //no ufunction for you cause FCollisionQueryParams can't be exposed
    bool GetObjectAtCursorLocation (FVector& PlayfieldLocation, FCollisionQueryParams& Params, AGameObject&out HoveredActor)
    {
        FVector CameraLoc = Gameplay::GetPlayerCameraManager(0).CameraLocation;
        FVector ProjectedLoc = ExtendPath(CameraLoc, PlayfieldLocation, 1000000);
        FHitResult Out;

        System::LineTraceSingleByChannel(Out, CameraLoc, ProjectedLoc, ECollisionChannel::Visibility, Params);
        //Print(f"{System::GetDisplayName(Out.GetActor())}", 0);
        HoveredActor = Cast<AGameObject>(Out.GetActor());
        return Out.bBlockingHit;
    }

    //Left to right, top to bottom traversal of 9 equally spaced quadrants of the screen starting from top left
    FVector2D GetToolTipOffset(int Quadrant)
    {
        switch(Quadrant)
        {
            case 0: return FVector2D(-0.5, -0.5);
            case 1: return FVector2D(0.5, -0.5);
            case 2: return FVector2D(1.0, -0.5);
            case 3: return FVector2D(-0.5, 0.5);
            case 4: return FVector2D(0.5, 1.5);
            case 5: return FVector2D(1.5, 0.5);
            case 6: return FVector2D(-0.5, 1.5);
            case 7: return FVector2D(0.5, 1.5);
            case 8: return FVector2D(1.5, 1.5);
            default:return FVector2D(0.5, 1.5);
        }
    }

    UFUNCTION()
    void GetTooltipParamsFromWorldLocation (APlayerController PlayerController, FVector WorldLocation, FVector2D&out ScreenPosition, FVector2D&out Offset)
    {
        FVector2D Temp;
        FVector2D ViewportSize = WidgetLayout::GetViewportSize();
        WidgetLayout::ProjectWorldLocationToWidgetPosition(PlayerController, WorldLocation, Temp, true);

        float X = Math::Clamp(Temp.X, 0, ViewportSize.X + 0.8);
        float Y = Math::Clamp(Temp.Y, 0, ViewportSize.Y + 0.8);

        ScreenPosition = FVector2D(X, Y);
        Offset = GetToolTipOffset(Math::RoundToInt(X / ViewportSize.X * 3.0) + Math::RoundToInt(Y / ViewportSize.Y * 3.0) * 3);
    }
}