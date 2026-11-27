// ScrollArrowListView.h
#pragma once

#include "CoreMinimal.h"
#include "Components/ListView.h"
#include "ScrollArrowButtonStyle.h"
#include "SScrollArrowListView.h"
#include "ScrollArrowListView.generated.h"

/**
 * A ListView whose scroll bar has an arrow button at each end.
 *
 *  - Click an arrow: scrolls one step.
 *  - Hold an arrow: after the repeat delay (default 0.5 s) it keeps scrolling until released or
 *    the end of the list is reached.
 *  - Arrow buttons are styled with per-state brushes, like the scroll bar handle (built-in arrow
 *    textures are used for anything left empty).
 *  - The sidebar (= scroll bar + the two arrow buttons) can have its own background brush and
 *    its own padding.
 *  - "Always Show Scroll Bar": keeps the arrows on screen (greyed out, track hidden) when there is
 *    not enough content to scroll.
 *
 * The scroll bar itself (thumb / track) still uses the list's regular "Scroll Bar Style", and that
 * style's Thickness is also the size of the arrow buttons and of the whole sidebar.
 */
UCLASS(meta = (DisplayName = "Scroll Arrow List View", EntryInterface = "/Script/UMG.UserObjectListEntry"))
class SPACETRADERS_API UScrollArrowListView : public UListView
{
	GENERATED_BODY()

public:
	UScrollArrowListView(const FObjectInitializer& ObjectInitializer);

	// ---- Behaviour -----------------------------------------------------------------------

	/**
	 * Keep the scroll bar area visible even when every item fits on screen. In that state the
	 * arrow buttons are greyed out and the scroll track is hidden.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows")
	bool bAlwaysShowScrollBar = false;

	/** Grey out an arrow button once its end of the list has been reached. */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows")
	bool bDisableArrowsAtScrollLimits = true;

	/** Items scrolled by a single click on an arrow. */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows", meta = (ClampMin = "0.01", UIMin = "0.1"))
	float ClickScrollAmount = 1.0f;

	/** Seconds an arrow must be held before it starts repeating (like the Windows keyboard repeat delay). */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows", meta = (ClampMin = "0.0", UIMin = "0.0"))
	float HoldRepeatDelay = 0.5f;

	/** Items per second scrolled while an arrow is held past the repeat delay. */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows", meta = (ClampMin = "0.1", UIMin = "1.0"))
	float HoldScrollSpeed = 12.0f;

	// ---- Style ---------------------------------------------------------------------------

	/**
	 * Background drawn behind the whole sidebar (arrow buttons + scroll bar). Unlike the list's own
	 * background it only exists while the side bar is on screen. Set "Draw As" to something other
	 * than None to enable it.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows|Style")
	FSlateBrush SideBarBackground;

	/**
	 * Spacing around the whole sidebar, outside its background. Use it to keep list entries away
	 * from the sidebar. Removed together with the sidebar when the sidebar is not shown.
	 * (The list's own "Scroll Bar Padding" still pads the scroll bar inside the sidebar.)
	 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows|Style")
	FMargin SideBarPadding;

	/**
	 * Use the start button style (up / left) for the end button (down / right) too.
	 * Untick this if you assign your own arrow textures, so each button can get its own direction.
	 * (The built-in arrows always point the right way either way.)
	 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows|Style")
	bool bUseSameStyleForBothButtons = true;

	/** Style of the up (vertical list) / left (horizontal list) arrow button. */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows|Style")
	FScrollArrowButtonStyle StartButtonStyle;

	/** Style of the down (vertical list) / right (horizontal list) arrow button. */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Scroll Arrows|Style", meta = (EditCondition = "!bUseSameStyleForBothButtons"))
	FScrollArrowButtonStyle EndButtonStyle;

	// ---- Runtime API ---------------------------------------------------------------------

	UFUNCTION(BlueprintCallable, Category = "Scroll Arrows")
	void SetAlwaysShowScrollBar(bool bInAlwaysShowScrollBar);

	UFUNCTION(BlueprintPure, Category = "Scroll Arrows")
	bool GetAlwaysShowScrollBar() const { return bAlwaysShowScrollBar; }

	UFUNCTION(BlueprintCallable, Category = "Scroll Arrows")
	void SetSideBarBackground(const FSlateBrush& InBrush);

	UFUNCTION(BlueprintCallable, Category = "Scroll Arrows")
	void SetSideBarPadding(const FMargin& InPadding);

	UFUNCTION(BlueprintCallable, Category = "Scroll Arrows")
	void SetStartButtonStyle(const FScrollArrowButtonStyle& InStyle);

	UFUNCTION(BlueprintCallable, Category = "Scroll Arrows")
	void SetEndButtonStyle(const FScrollArrowButtonStyle& InStyle);

	//~ Begin UWidget Interface
	virtual void SynchronizeProperties() override;
	virtual void ReleaseSlateResources(bool bReleaseChildren) override;
	//~ End UWidget Interface

protected:
	//~ Begin UListViewBase Interface
	virtual TSharedRef<STableViewBase> RebuildListWidget() override;
	//~ End UListViewBase Interface

private:
	FScrollArrowBarSettings MakeSlateSettings() const;
	void ApplyArrowSettings();

	TWeakPtr<SScrollArrowListView<UObject*>> MyArrowListView;
};
