// SScrollArrowBar.cpp
#include "SScrollArrowBar.h"

#include "Rendering/DrawElements.h"
#include "Styling/CoreStyle.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Layout/SBox.h"
#include "Widgets/Layout/SScrollBar.h"
#include "Widgets/SBoxPanel.h"

namespace
{
	// Fractions of the scroll track; tight enough to be exact for lists with 100k+ items.
	constexpr float LimitTolerance = 1.e-5f;
}

// ---------------------------------------------------------------------------------------------
// SScrollArrowGlyph
// ---------------------------------------------------------------------------------------------

void SScrollArrowGlyph::Construct(const FArguments& InArgs)
{
	Direction = InArgs._Direction;
}

void SScrollArrowGlyph::SetStyle(const FScrollArrowButtonStyle& InStyle)
{
	ArrowImage = InStyle.ArrowImage;
	GlyphSize = InStyle.ArrowSize;
	LineThickness = InStyle.ArrowLineThickness;
	Invalidate(EInvalidateWidgetReason::Layout);
}

bool SScrollArrowGlyph::HasImage() const
{
	return ArrowImage.GetResourceObject() != nullptr || !ArrowImage.GetResourceName().IsNone();
}

FVector2D SScrollArrowGlyph::ComputeDesiredSize(float /*LayoutScaleMultiplier*/) const
{
	return GlyphSize;
}

int32 SScrollArrowGlyph::OnPaint(const FPaintArgs& Args, const FGeometry& AllottedGeometry, const FSlateRect& MyCullingRect,
	FSlateWindowElementList& OutDrawElements, int32 LayerId, const FWidgetStyle& InWidgetStyle, bool bParentEnabled) const
{
	const bool bEnabled = ShouldBeEnabled(bParentEnabled);
	const ESlateDrawEffect DrawEffects = bEnabled ? ESlateDrawEffect::None : ESlateDrawEffect::DisabledEffect;

	// The parent SButton publishes its per-state colour as the "foreground" colour.
	const FLinearColor Tint = InWidgetStyle.GetColorAndOpacityTint() * FSlateColor::UseForeground().GetColor(InWidgetStyle);

	const FVector2f LocalSize = AllottedGeometry.GetLocalSize();
	const FVector2f Size(static_cast<float>(GlyphSize.X), static_cast<float>(GlyphSize.Y));
	const FVector2f Center = LocalSize * 0.5f;

	if (HasImage())
	{
		const FVector2f TopLeft = Center - Size * 0.5f;
		FSlateDrawElement::MakeBox(
			OutDrawElements,
			LayerId,
			AllottedGeometry.ToPaintGeometry(Size, FSlateLayoutTransform(TopLeft)),
			&ArrowImage,
			DrawEffects,
			Tint * ArrowImage.GetTint(InWidgetStyle));
	}
	else
	{
		const float Hx = Size.X * 0.5f;
		const float Hy = Size.Y * 0.5f;

		TArray<FVector2f> Points;
		Points.Reserve(3);

		switch (Direction)
		{
		case EScrollArrowDirection::Up:
			Points.Add(FVector2f(Center.X - Hx, Center.Y + Hy * 0.5f));
			Points.Add(FVector2f(Center.X,      Center.Y - Hy * 0.5f));
			Points.Add(FVector2f(Center.X + Hx, Center.Y + Hy * 0.5f));
			break;
		case EScrollArrowDirection::Down:
			Points.Add(FVector2f(Center.X - Hx, Center.Y - Hy * 0.5f));
			Points.Add(FVector2f(Center.X,      Center.Y + Hy * 0.5f));
			Points.Add(FVector2f(Center.X + Hx, Center.Y - Hy * 0.5f));
			break;
		case EScrollArrowDirection::Left:
			Points.Add(FVector2f(Center.X + Hx * 0.5f, Center.Y - Hy));
			Points.Add(FVector2f(Center.X - Hx * 0.5f, Center.Y));
			Points.Add(FVector2f(Center.X + Hx * 0.5f, Center.Y + Hy));
			break;
		case EScrollArrowDirection::Right:
		default:
			Points.Add(FVector2f(Center.X - Hx * 0.5f, Center.Y - Hy));
			Points.Add(FVector2f(Center.X + Hx * 0.5f, Center.Y));
			Points.Add(FVector2f(Center.X - Hx * 0.5f, Center.Y + Hy));
			break;
		}

		FSlateDrawElement::MakeLines(
			OutDrawElements,
			LayerId,
			AllottedGeometry.ToPaintGeometry(),
			Points,
			DrawEffects,
			Tint,
			/*bAntialias*/ true,
			LineThickness);
	}

	return LayerId;
}

// ---------------------------------------------------------------------------------------------
// SScrollArrowBar
// ---------------------------------------------------------------------------------------------

void SScrollArrowBar::Construct(const FArguments& InArgs)
{
	Orientation = InArgs._Orientation;
	OnScroll = InArgs._OnScroll;
	UserScrollbarVisibility = InArgs._ScrollbarVisibility;

	const FScrollBarStyle* BarStyle = InArgs._ScrollBarStyle
		? InArgs._ScrollBarStyle
		: &FCoreStyle::Get().GetWidgetStyle<FScrollBarStyle>("Scrollbar");

	SAssignNew(ScrollBar, SScrollBar)
		.Style(BarStyle)
		.Orientation(Orientation);

	const TSharedRef<SWidget> StartWidget = MakeArrowButton(/*bIsEnd*/ false);
	const TSharedRef<SWidget> EndWidget = MakeArrowButton(/*bIsEnd*/ true);

	// Hidden (not Collapsed) keeps the slot, so the arrows stay pinned to the ends of the bar.
	const TSharedRef<SWidget> TrackWidget =
		SNew(SBox)
		.Visibility(this, &SScrollArrowBar::GetTrackVisibility)
		[
			ScrollBar.ToSharedRef()
		];

	if (Orientation == Orient_Vertical)
	{
		ChildSlot
		[
			SNew(SVerticalBox)
			+ SVerticalBox::Slot().AutoHeight()[ StartWidget ]
			+ SVerticalBox::Slot().FillHeight(1.0f)[ TrackWidget ]
			+ SVerticalBox::Slot().AutoHeight()[ EndWidget ]
		];
	}
	else
	{
		ChildSlot
		[
			SNew(SHorizontalBox)
			+ SHorizontalBox::Slot().AutoWidth()[ StartWidget ]
			+ SHorizontalBox::Slot().FillWidth(1.0f)[ TrackWidget ]
			+ SHorizontalBox::Slot().AutoWidth()[ EndWidget ]
		];
	}

	SetVisibility(MakeAttributeSP(this, &SScrollArrowBar::GetBarVisibility));

	ApplyStyles();
}

TSharedRef<SWidget> SScrollArrowBar::MakeArrowButton(bool bIsEnd)
{
	const bool bVertical = (Orientation == Orient_Vertical);
	const EScrollArrowDirection Direction = bIsEnd
		? (bVertical ? EScrollArrowDirection::Down : EScrollArrowDirection::Right)
		: (bVertical ? EScrollArrowDirection::Up : EScrollArrowDirection::Left);

	TSharedPtr<SScrollArrowGlyph>& Glyph = bIsEnd ? EndGlyph : StartGlyph;
	TSharedPtr<SButton>& Button = bIsEnd ? EndButton : StartButton;
	TSharedPtr<SBox>& SizeBox = bIsEnd ? EndSizeBox : StartSizeBox;
	FButtonStyle& SlateStyle = bIsEnd ? EndSlateStyle : StartSlateStyle;

	SAssignNew(Glyph, SScrollArrowGlyph).Direction(Direction);

	if (bIsEnd)
	{
		SAssignNew(Button, SButton)
			.ButtonStyle(&SlateStyle)
			.ContentPadding(FMargin(0.0f))
			.HAlign(HAlign_Center)
			.VAlign(VAlign_Center)
			.IsFocusable(false) // never steal keyboard / gamepad focus from the list
			.IsEnabled(this, &SScrollArrowBar::IsEndEnabled)
			.ForegroundColor(this, &SScrollArrowBar::GetEndForeground)
			.OnPressed(this, &SScrollArrowBar::HandleEndPressed)
			.OnReleased(this, &SScrollArrowBar::HandleEndReleased)
			[
				Glyph.ToSharedRef()
			];
	}
	else
	{
		SAssignNew(Button, SButton)
			.ButtonStyle(&SlateStyle)
			.ContentPadding(FMargin(0.0f))
			.HAlign(HAlign_Center)
			.VAlign(VAlign_Center)
			.IsFocusable(false)
			.IsEnabled(this, &SScrollArrowBar::IsStartEnabled)
			.ForegroundColor(this, &SScrollArrowBar::GetStartForeground)
			.OnPressed(this, &SScrollArrowBar::HandleStartPressed)
			.OnReleased(this, &SScrollArrowBar::HandleStartReleased)
			[
				Glyph.ToSharedRef()
			];
	}

	SAssignNew(SizeBox, SBox)
	[
		Button.ToSharedRef()
	];

	return SizeBox.ToSharedRef();
}

void SScrollArrowBar::SetSettings(const FScrollArrowBarSettings& InSettings)
{
	Settings = InSettings;
	ApplyStyles();
	ScrollBar->InvalidateStyle();
	Invalidate(EInvalidateWidgetReason::Layout);
}

void SScrollArrowBar::ApplyStyles()
{
	ConfigureButton(StartButton, StartSizeBox, StartGlyph, StartSlateStyle, Settings.StartButtonStyle);
	ConfigureButton(EndButton, EndSizeBox, EndGlyph, EndSlateStyle, Settings.EndButtonStyle);
}

void SScrollArrowBar::ConfigureButton(const TSharedPtr<SButton>& Button, const TSharedPtr<SBox>& SizeBox,
	const TSharedPtr<SScrollArrowGlyph>& Glyph, FButtonStyle& SlateStyle, const FScrollArrowButtonStyle& Style) const
{
	SlateStyle
		.SetNormal(Style.NormalImage)
		.SetHovered(Style.HoveredImage)
		.SetPressed(Style.PressedImage)
		.SetDisabled(Style.DisabledImage)
		.SetNormalPadding(FMargin(0.0f))
		.SetPressedPadding(FMargin(0.0f));

	Button->SetButtonStyle(&SlateStyle);

	const bool bVertical = (Orientation == Orient_Vertical);
	SizeBox->SetWidthOverride(FOptionalSize(bVertical ? Style.ButtonThickness : Style.ButtonLength));
	SizeBox->SetHeightOverride(FOptionalSize(bVertical ? Style.ButtonLength : Style.ButtonThickness));

	Glyph->SetStyle(Style);
}

// ---------------------------------------------------------------------------------------------
// Visibility / enabled state
// ---------------------------------------------------------------------------------------------

EVisibility SScrollArrowBar::GetBarVisibility() const
{
	// The list's own "Scrollbar Visibility" (Collapsed / Hidden) always wins.
	const EVisibility UserVisibility = UserScrollbarVisibility.Get(EVisibility::Visible);
	if (!UserVisibility.IsVisible())
	{
		return UserVisibility;
	}

	if (ScrollBar->IsNeeded())
	{
		// Content overflows: behave like the stock scroll bar (also honours SetScrollbarVisibility at runtime).
		return ScrollBar->ShouldBeVisible();
	}

	// Nothing to scroll: either keep the (greyed out) arrows around, or vanish like a normal scroll bar.
	return Settings.bAlwaysShowScrollBar ? EVisibility::Visible : EVisibility::Collapsed;
}

EVisibility SScrollArrowBar::GetTrackVisibility() const
{
	return ScrollBar->IsNeeded() ? EVisibility::Visible : EVisibility::Hidden;
}

bool SScrollArrowBar::CanScrollInDirection(bool bTowardsEnd) const
{
	if (!ScrollBar->IsNeeded())
	{
		return false;
	}

	const float Remaining = bTowardsEnd ? ScrollBar->DistanceFromBottom() : ScrollBar->DistanceFromTop();
	return Remaining > LimitTolerance;
}

bool SScrollArrowBar::IsArrowEnabled(bool bIsEnd) const
{
	if (!ScrollBar->IsNeeded())
	{
		return false;
	}

	return Settings.bDisableArrowsAtLimits ? CanScrollInDirection(bIsEnd) : true;
}

FSlateColor SScrollArrowBar::GetArrowForeground(bool bIsEnd) const
{
	const FScrollArrowButtonStyle& Style = bIsEnd ? Settings.EndButtonStyle : Settings.StartButtonStyle;
	const TSharedPtr<SButton>& Button = bIsEnd ? EndButton : StartButton;

	if (!Button.IsValid() || !Button->IsEnabled())
	{
		return FSlateColor(Style.ArrowDisabledTint);
	}
	if (Button->IsPressed())
	{
		return FSlateColor(Style.ArrowPressedTint);
	}
	if (Button->IsHovered())
	{
		return FSlateColor(Style.ArrowHoveredTint);
	}
	return FSlateColor(Style.ArrowNormalTint);
}

// ---------------------------------------------------------------------------------------------
// Click + hold-to-repeat
// ---------------------------------------------------------------------------------------------

void SScrollArrowBar::BeginHold(bool bTowardsEnd)
{
	StopHoldTimer();

	if (!CanScrollInDirection(bTowardsEnd))
	{
		HeldDirection = 0;
		return;
	}

	HeldDirection = bTowardsEnd ? 1 : -1;
	HeldTime = 0.0f;

	// The plain "click": one step immediately on press.
	OnScroll.ExecuteIfBound(static_cast<float>(HeldDirection) * Settings.ClickScrollAmount);

	// After the repeat delay the timer takes over and keeps scrolling until release / end of list.
	HoldTimerHandle = RegisterActiveTimer(0.0f, FWidgetActiveTimerDelegate::CreateSP(this, &SScrollArrowBar::HandleHoldTimer));
}

void SScrollArrowBar::EndHold()
{
	HeldDirection = 0;
	StopHoldTimer();
}

void SScrollArrowBar::StopHoldTimer()
{
	if (const TSharedPtr<FActiveTimerHandle> Handle = HoldTimerHandle.Pin())
	{
		UnRegisterActiveTimer(Handle.ToSharedRef());
	}
	HoldTimerHandle.Reset();
}

EActiveTimerReturnType SScrollArrowBar::HandleHoldTimer(double InCurrentTime, float InDeltaTime)
{
	if (HeldDirection == 0)
	{
		return EActiveTimerReturnType::Stop;
	}

	HeldTime += InDeltaTime;
	if (HeldTime < Settings.HoldRepeatDelay)
	{
		return EActiveTimerReturnType::Continue;
	}

	if (!CanScrollInDirection(HeldDirection > 0))
	{
		// Reached the end of the list: nothing left to do until the button is pressed again.
		HeldDirection = 0;
		return EActiveTimerReturnType::Stop;
	}

	OnScroll.ExecuteIfBound(static_cast<float>(HeldDirection) * Settings.HoldScrollSpeed * InDeltaTime);
	return EActiveTimerReturnType::Continue;
}
