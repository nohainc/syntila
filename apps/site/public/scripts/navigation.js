const toggle = /** @type {HTMLButtonElement | null} */ (
  document.querySelector(".menu-toggle")
);
const navigation = document.querySelector("#site-navigation");

if (toggle && navigation) {
  const closeMenu = () => {
    toggle.setAttribute("aria-expanded", "false");
    navigation.removeAttribute("data-open");
  };

  toggle.addEventListener("click", () => {
    const isOpen = toggle.getAttribute("aria-expanded") === "true";
    toggle.setAttribute("aria-expanded", String(!isOpen));
    if (isOpen) navigation.removeAttribute("data-open");
    else navigation.setAttribute("data-open", "");
  });

  navigation
    .querySelectorAll("a")
    .forEach((link) => link.addEventListener("click", closeMenu));
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && navigation.hasAttribute("data-open")) {
      closeMenu();
      toggle.focus();
    }
  });
}
