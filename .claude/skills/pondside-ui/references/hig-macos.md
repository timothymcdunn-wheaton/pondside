# Apple HIG — macOS digest

Distilled 2026-10-28 from developer.apple.com/design/human-interface-guidelines
(JSON form: `developer.apple.com/tutorials/data/design/human-interface-guidelines/<slug>.json`).
Quotes are Apple's words. Re-fetch a page when a decision hinges on exact wording;
the typography table and the start of the accent-colour section were summarized, not
read verbatim.

## Contents
- Designing for macOS · Windows · Panels · Popovers · Sheets
- Materials · Color · Dark Mode · Typography · Layout
- Motion · Feedback · Loading · Focus and selection · Keyboards · Accessibility

## Designing for macOS
- Users are stationary, keyboard plus pointer. "Leverage large displays to present more
  content in fewer nested levels and with less need for modality."
- Transitions between active and inactive states should be smooth. Support keyboard-only work.

## Windows
- Main window: one per app. Key window: "accepts people's input", one onscreen. A panel
  floating above the main window "might be key instead".
- Panels "become the key window only when people click the window's title bar or a
  component that requires keyboard input".
- Inactive windows drop vibrancy and look subdued.
- "Avoid putting critical information or actions in a bottom bar." Prefer system
  appearances over custom window UI.

## Panels (macOS only)
- Float above windows with "supplementary controls, options, or information related to
  the active window or current selection"; "less prominent" than the main window.
- Prefer sliders/steppers over typing controls. Titles are short nouns ("Inspector").
- Show with the app active, hide when inactive; no minimize; not in the Window menu's
  document list.
- HUD style ("darker and translucent") only for media apps, when a standard panel would
  hide essential content, or when there are no controls. "Prefer standard panels."
  HUDs: colour sparingly, keep small, never obscure or compete with the content they adjust.
- Keep one panel style across modes.

## Popovers
- "A transient view that appears above other content", for "a small amount of
  information or functionality".
- Point at its origin and "ideally … doesn't cover the element that revealed it or any
  essential content people may need to see while using it."
- Nonmodal popovers close on outside click; always save work on auto-close.
- One at a time; nothing stacked over it except an alert. Not for warnings.
- Only as big as its content; animate size changes. Detached popovers become panels with
  minimal appearance change.

## Sheets
- Always modal on macOS; dims the parent. Use a panel instead "if people need to
  repeatedly provide input and observe results". Cancel/Done/Back semantics.
- Use as the reference for what a transient, non-blocking view should NOT look like.

## Materials
- Liquid Glass is for controls/navigation floating above content; "Don't use Liquid Glass
  in the content layer." Use it sparingly. Regular variant for text-heavy components;
  clear only over rich backgrounds (consider a 35% dark dim when bright).
- Standard materials for the content layer; choose by semantic purpose, not colour.
- "Thicker materials … provide better contrast for text and other elements with fine
  features. Thinner materials … help people retain their context."
- Use vibrant system colours on materials. macOS blending: behind-window / within-window.
- Appearance adapts under Reduce Transparency and Increase Contrast — custom layers must too.

## Color
- Prefer system/semantic colours; values change between releases.
- Custom colours need light, dark and increased-contrast variants.
- One colour, one meaning; don't redefine semantic system colours.
- Never rely on colour alone — add a shape, glyph or label.
- macOS dynamic colours: controlAccent, keyboardFocusIndicator, selectedContentBackground,
  unemphasizedSelectedContentBackground (non-key), selectedTextBackground,
  selectedControl, findHighlight.
- The user's chosen accent replaces the app accent unless set to multicolor.

## Dark Mode
- Follow the system; "Avoid offering an app-specific appearance setting." Handle Auto
  switching while running.
- Test with Increase Contrast and Reduce Transparency, separately and together.
- Contrast ≥ 4.5:1; aim for 7:1 for small custom text.
- "Soften the color of white backgrounds" in content images so they don't glow.
- On macOS, transparency on custom components only in a neutral state, not a coloured one.

## Typography
- macOS has no Dynamic Type. Default 13 pt, minimum 10 pt. Avoid light/thin weights.
  Few typefaces. Use system font roles (labelFont, controlContentFont, …).
- Text styles (pt size/leading, summarized): Large Title 26/32, Title 1 22/26,
  Title 2 17/22, Title 3 15/20, Headline 13/16 bold, Body 13/16, Callout 12/15,
  Subheadline 11/14, Footnote 10/13, Caption 1 10/13, Caption 2 10/13 medium.

## Layout
- Most important content at top and leading edge. Differentiate controls from content.
- Avoid critical controls/info at the bottom of a window. Use system layout guides and
  safe areas. (No macOS margin numbers given; accessibility suggests ~12 pt padding around
  bezelled elements, ~24 pt without a bezel.)

## Motion
- "Add motion purposefully." "Make motion optional" — never the only carrier of information.
- "Generally avoid adding motion to UI interactions that occur frequently."
- Brief, precise feedback animations. "Don't make people wait for an animation to complete."
- Fade rather than slide when relocating something. No durations are specified.

## Feedback
- Match delivery to significance: status passive, data-loss warnings interruptive.
- Put status "near the items it describes". Alerts for critical, actionable info.
- Explain when a command can't be carried out.

## Loading
- "The best content-loading experience finishes before people become aware of it."
- Show something as soon as possible; placeholders replaced as content arrives.
- Let people keep working while waiting. Determinate progress when duration is known.

## Focus and selection
- "Avoid changing focus without people's interaction." If the focused item disappears,
  hide the focus indicator.
- Focus ring for text fields, highlight (accent) in lists/collections.

## Keyboards
- Support Full Keyboard Access. Don't repurpose standard shortcuts.
- Esc: "Cancel the current action or process." ⌘. cancels an operation.
- Command as main modifier; avoid Control; Option sparingly; order ⌃⌥⇧⌘.
- Custom shortcuts only for the most frequent app-specific commands.

## Accessibility
- Contrast (WCAG AA): ≤17 pt 4.5:1; ≥18 pt or bold 3:1. If defaults fall short, provide a
  higher-contrast scheme under Increase Contrast.
- Allow text enlargement. Controls 28×28 pt default, 20×20 pt minimum.
- Everything reachable by keyboard; don't override system shortcuts.
- Timer-dismissed views are a problem; prefer explicit dismissal.
- Reduce Motion: cut zoom/scale/peripheral motion, tighten springs, replace axis
  transitions with fades, "avoid animating into and out of blurs."
- Label UI and content for VoiceOver.
