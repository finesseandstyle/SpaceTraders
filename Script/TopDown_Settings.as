class UTopDown_Settings : UGameUserSettings
{
    //Sound
    //we use log volume control: https://dcordero.me/posts/logarithmic_volume_control.html
    private float MasterVolume      = Math::Pow(0.5, 2);;
    private float SoundEffectVolume = 1.0;
    private float MusicVolume       = 1.0;
    private float DialogueVolume    = 1.0;
    
    //Game Logic
    private float TurnDuration      = 4.0;

    //Use this for the UI to set that value for a slider
    UFUNCTION()
    float GetMasterVolume() const { return Math::Sqrt(MasterVolume); }
    UFUNCTION()
    void SetMasterVolume(float NewMasterVolume) { MasterVolume = Math::Pow(NewMasterVolume, 2); }
    UFUNCTION()
    float GetSoundEffectVolume() const { return SoundEffectVolume; }
    UFUNCTION()
    void SetSoundEffectVolume(float NewSoundEffectVolume) { SoundEffectVolume = NewSoundEffectVolume; }
    UFUNCTION()
    float GetMusicVolume() const { return MusicVolume; }
    UFUNCTION()
    void SetMusicVolume(float NewMusicVolume) { MusicVolume = NewMusicVolume; }
    UFUNCTION()
    float GetDialogueVolume() const { return DialogueVolume; }
    UFUNCTION()
    void SetDialogueVolume(float NewDialogueVolume) { DialogueVolume = NewDialogueVolume; }

    //The actual values that will be used under the hood
    UFUNCTION()
    float GetRealSoundEffectVolume() const {
        return MasterVolume * SoundEffectVolume;
    }
    UFUNCTION()
    float GetRealMusicVolume() const {
        return MasterVolume * MusicVolume;
    }
    UFUNCTION()
    float GetRealDialogueVolume() const {
        return MasterVolume * DialogueVolume;
    }

    
    UFUNCTION()
    float GetTurnDuration() const { return TurnDuration; }
    UFUNCTION()
    void SetTurnDuration(float NewTurnDuration) 
    { 
        TurnDuration = Math::Clamp(NewTurnDuration, 2.0f, 10.0f); 
        Cast<ATopDown_GameState>(Gameplay::GetGameState()).SetNewTurnDuration(TurnDuration);
    }
}