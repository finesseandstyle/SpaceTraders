event void FOnTurnUpdate2();
event void FOnTurnResume2();
event void FOnTurnPaused2();
event void FOnSmallObjectSpawned2();
event void FOnSmallObjectDestroyed2();
event void FOnGameStateInitialized();

class ATopDown_GameState : AGameStateBase
{
    const FTimespan OneTurn = FTimespan::FromDays(1);

    UPROPERTY() FOnTurnUpdate2 OnTurnUpdate;
    UPROPERTY() FOnTurnResume2 OnTurnResume;
    UPROPERTY() FOnTurnPaused2 OnTurnPaused;
    UPROPERTY() FOnSmallObjectSpawned2 OnSmallObjectSpawned;
    UPROPERTY() FOnSmallObjectDestroyed2 OnSmallObjectDestroyed;
    UPROPERTY() FOnGameStateInitialized OnGameStateReady;

    //1 January 3300
    UPROPERTY() FDateTime CurrentTurnDate = FDateTime(3300,1,1); 
    
    //World Stuff, Ships spawn in their own horizontal plane
    UPROPERTY() float LocalWorldHalfSize = 200000.0; //depends on the star system
    UPROPERTY() float MinZPlane = 700.0;
    UPROPERTY() float MaxZPlane = 1100;
    
    //Turn Logic stuff
    private FTimerHandle TurnTimer;
    UPROPERTY() float TurnDuration;//USpaceTradersSettings::GetUserSettings().TurnDuration;

    //We default 1.0 at turn's end like it's 23:59, just before a new day/turn
    UPROPERTY() float NormalizedTurnProgress = 1.0; 
    UPROPERTY() bool bIsGamePaused = false;

    UPROPERTY() TArray<AGameObject> GameObjects;

    bool bQueuePause = false;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        //Print("hello");
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
        //This is the single authority where we can get the turn's normalized progress, everyone else queries it from here.
        //NormalizedTurnProgress = System::IsValidTimerHandle(TurnTimer) ? 
        NormalizedTurnProgress = System::GetTimerElapsedTimeHandle(TurnTimer) / TurnDuration; //: 1.0; 
        /*for (int32 i = 0; i < GameObjects.Num(); i++)
        {
            GameObjects[i].Update(NormalizedTurnProgress);
        }*/
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
            
            for (AGameObject GameObject : GameObjects)
            {
                if (GameObject != nullptr) //Dirty fix for destroyed objects not updating the array
                    GameObject.TurnResume();
            }
            OnTurnResume.Broadcast();
            HandleTurn();
        }
    }

    UFUNCTION()
    void SetNewTurnDuration(float NewTurnDuration)
    {
        if (bIsGamePaused)
        {
            TurnDuration = NewTurnDuration; //input validation is done inside settings menu UI
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
}