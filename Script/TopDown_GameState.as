event void FOnTurnUpdate();
event void FOnTurnResume();
event void FOnTurnPaused();
event void FOnTurnDurationChanged();
event void FOnSmallObjectSpawned(USceneComponent RootComponent, FGameplayTag ObjectType, FGameplayTag Race);
event void FOnSmallObjectDestroyed(USceneComponent RootComponent);
event void FOnGameStateInitialized();

class ATopDown_GameState : AGameStateBase
{
    const FTimespan OneTurn = FTimespan::FromDays(1);

    UPROPERTY() FOnTurnUpdate OnTurnUpdate;
    UPROPERTY() FOnTurnResume OnTurnResume;
    UPROPERTY() FOnTurnPaused OnTurnPaused;
    UPROPERTY() FOnTurnDurationChanged OnTurnDurationChanged;
    UPROPERTY() FOnSmallObjectSpawned OnSmallObjectSpawned;
    UPROPERTY() FOnSmallObjectDestroyed OnSmallObjectDestroyed;
    UPROPERTY() FOnGameStateInitialized OnGameStateReady;

    //1 January 3300
    UPROPERTY() FDateTime CurrentTurnDate = FDateTime(3300,1,1); 
    
    //World Stuff, Ships spawn in their own horizontal plane
    UPROPERTY() float LocalWorldHalfSize = 200000.0; //depends on the star system
    UPROPERTY() float MinZPlane = 5700.0;
    UPROPERTY() float MaxZPlane = 6100;
    
    //Turn Logic stuff
    private FTimerHandle TurnTimer;
    UPROPERTY() float TurnDuration;//USpaceTradersSettings::GetUserSettings().TurnDuration;

    //We default 1.0 at turn's end like it's 23:59, just before a new day/turn
    UPROPERTY() float NormalizedTurnProgress = 1.0; 
    UPROPERTY() bool bIsGamePaused = false;

    UPROPERTY() TArray<AGameObject> GameObjects;
    UPROPERTY() TArray<AGameObject> Planets;

    bool bQueuePause = false;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        bQueuePause = true;
        bIsGamePaused = true;
        TurnDuration = UTopDown_Settings().GetTurnDuration();

        OnGameStateReady.Broadcast();

        GetAllActorsOfClass(GameObjects);
        HandleTurn();
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaSeconds)
    {
        NormalizedTurnProgress = System::GetTimerElapsedTimeHandle(TurnTimer) / TurnDuration;
    }

    //Returns real time seconds elapsed after turn start
    UFUNCTION(BlueprintPure)
    float GetElapsedTime()
    {
        return System::GetTimerElapsedTimeHandle(TurnTimer);
    }

    UFUNCTION()
    void TogglePause(bool&out bIsQueuePaused)
    {
        if (bQueuePause)
        {
            TryResumeTurn();
        }
        else 
        {
            TryPauseTurn();
        }
        bIsQueuePaused = bQueuePause;
    }

    UFUNCTION()
    void TryPauseTurn()
    {
        bQueuePause = true;
    }

    UFUNCTION()
    void TryResumeTurn()
    {
        bQueuePause = false;
        if (bIsGamePaused)
        {
            SetActorTickEnabled(true);
            NormalizedTurnProgress = 0.0; //otherwise ships will teleport to their destination on the 1st frame
            
            OnTurnResume.Broadcast();
            HandleTurn();
            for (AGameObject GameObject : GameObjects)
            {
                if (GameObject != nullptr) //Dirty fix for destroyed objects not updating the array
                    GameObject.TurnResume();
            }
        }
    }

    UFUNCTION()
    void SetNewTurnDuration(float NewTurnDuration)
    {
        if (bIsGamePaused)
        {
            TurnDuration = NewTurnDuration; //input validation is done inside settings menu UI;
            OnTurnDurationChanged.Broadcast();
        }
    }

    UFUNCTION()
    void HandleTurn()
    {
        if (!bQueuePause)
        {
            CurrentTurnDate = CurrentTurnDate + OneTurn;
            bIsGamePaused = false;

            for (AGameObject GameObject : GameObjects)
            {
                GameObject.TurnUpdate();
            }
            OnTurnUpdate.Broadcast();


            TurnTimer = System::SetTimer(this, n"HandleTurn", TurnDuration, false);
        }
        else
        {   
            SetActorTickEnabled(false);
            bIsGamePaused = true;
            
            for (AGameObject GameObject : GameObjects)
            {
                GameObject.TurnPause();
            }
            OnTurnPaused.Broadcast();

            System::ClearAndInvalidateTimerHandle(TurnTimer);
        }
    }
};