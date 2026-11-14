if (navigator.clipboard && window.isSecureContext) {
  document.querySelectorAll('.downloads-install pre, .downloads-cli-box pre').forEach((pre) => {
    const code = pre.querySelector('code');
    if (!code) return;
    const wrap = document.createElement('div');
    wrap.className = 'command-copy-wrap';
    pre.before(wrap);
    wrap.append(pre);
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'command-copy';
    button.setAttribute('aria-label', 'Copy command');
    button.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>';
    const status = document.createElement('span');
    status.className = 'command-copy__status';
    status.setAttribute('role', 'status');
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(code.textContent || '');
        status.textContent = 'Copied';
      } catch {
        status.textContent = 'Copy failed; select the text instead';
      }
    });
    wrap.append(button, status);
  });
}
