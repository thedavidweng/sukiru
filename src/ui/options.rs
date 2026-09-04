use gpui::SharedString;
use gpui_component::select::SelectItem;

/// One selectable entry in a dropdown. The closed input shows `title`;
/// `value` is the stable token written back into preferences or session
/// filters ("", "~untagged", a workspace id, a theme key, …).
#[derive(Clone)]
pub struct ChoiceOption {
    title: SharedString,
    value: String,
}

impl ChoiceOption {
    /// Sentinel value behind the untagged tag filter.
    pub const UNTAGGED: &str = "~untagged";
    /// Sentinel value behind the "no filter" option of both filters.
    pub const ALL: &str = "";

    pub fn new(title: impl Into<SharedString>, value: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            value: value.into(),
        }
    }

    pub fn all() -> Self {
        Self::new("All", Self::ALL)
    }

    pub fn value(&self) -> &str {
        &self.value
    }
}

impl SelectItem for ChoiceOption {
    type Value = String;

    fn title(&self) -> SharedString {
        self.title.clone()
    }

    fn value(&self) -> &String {
        &self.value
    }
}
