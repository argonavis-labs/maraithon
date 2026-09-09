// Apply the saved appearance before first paint on web and desktop.
(() => {
  const media = matchMedia('(prefers-color-scheme: dark)');
  const apply = () => {
    let preference = 'system';
    try { preference = localStorage.getItem('maraithon:theme') || 'system'; } catch {}
    document.documentElement.classList.toggle('dark', preference === 'dark' || (preference === 'system' && media.matches));
    document.documentElement.dataset.theme = preference;
  };
  apply();
  media.addEventListener('change', apply);
  addEventListener('storage', apply);
  addEventListener('maraithon:theme', apply);
})();
