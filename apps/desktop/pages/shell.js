// Only fixed shell commands cross the preload boundary.
const status = document.querySelector('#status');
async function perform(button, action, message) {
  button.disabled = true;
  status.textContent = message;
  try { await action(); } catch { status.textContent = 'Could not continue. Please try again.'; }
  finally { button.disabled = false; }
}
document.querySelector('#sign-in')?.addEventListener('click', event => perform(event.currentTarget, () => window.maraithonDesktop.signIn(), 'Finish signing in in your browser, then come back here.'));
document.querySelector('#retry')?.addEventListener('click', event => perform(event.currentTarget, () => window.maraithonDesktop.retry(), 'Connecting to your workspace…'));
document.querySelector('#sources')?.addEventListener('click', () => window.maraithonDesktop.openSources());
if (window.maraithonDesktop.platform !== 'darwin') {
  document.querySelector('#sources')?.remove();
  document.querySelector('.local-context')?.remove();
}
