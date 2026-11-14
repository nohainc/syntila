const endpoint = document.body.dataset.siteAnalyticsEndpoint || "";
const allowedEvents = new Set([
  "landing.page_view",
  "cta.open_app",
  "cta.download",
  "navigation.downloads",
  "navigation.how_it_works",
  "section.workspace_reached",
  "section.workers_reached",
]);

/** @param {string} event */
function track(event) {
  if (!endpoint || !allowedEvents.has(event)) return;
  const body = JSON.stringify({
    event,
    path: window.location.pathname,
    timestamp: Date.now(),
  });
  fetch(endpoint, {
    method: "POST",
    body,
    credentials: "omit",
    keepalive: true,
    headers: { "content-type": "text/plain" },
  }).catch(() => {});
}

if (window.location.pathname === "/") track("landing.page_view");

document.querySelectorAll("[data-site-event]").forEach((element) => {
  const event = element.getAttribute("data-site-event");
  if (event?.startsWith("cta.") || event?.startsWith("navigation.")) {
    element.addEventListener("click", () => track(event), { once: true });
  }
});

if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          const event = entry.target.getAttribute("data-site-event");
          if (event?.startsWith("section.")) track(event);
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.35 },
  );
  document
    .querySelectorAll('[data-site-event^="section."]')
    .forEach((element) => observer.observe(element));
}
