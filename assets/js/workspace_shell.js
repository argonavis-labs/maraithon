// Workspace chrome only. Todo events and durable drafts remain with LiveView.
export const WorkspaceShell = {
  mounted() {
    this.abort = new AbortController();
    const options = {signal: this.abort.signal};
    this.mobileNavigation = window.matchMedia('(max-width: 767px)');
    this.syncNavigation = () => {
      const open = this.mobileNavigation.matches && this.el.classList.contains('navigation-open');
      this.el.querySelector('.workspace-sidebar').inert = this.mobileNavigation.matches && !open;
      this.el.querySelector('.workspace-content').inert = open;
      this.el.querySelector('.workspace-mobile-header').inert = open;
    };
    this.mobileNavigation.addEventListener('change', this.syncNavigation, options);
    this.toggleNavigation = open => {
      this.el.classList.toggle('navigation-open', open);
      this.el.querySelector('[data-sidebar-toggle]')?.setAttribute('aria-expanded', String(open));
      this.syncNavigation();
      if (open) this.el.querySelector('.workspace-brand')?.focus();
    };
    this.el.addEventListener('click', event => {
      if (event.target.closest('[data-sidebar-toggle]')) this.toggleNavigation(!this.el.classList.contains('navigation-open'));
      if (event.target.closest('[data-sidebar-close], .workspace-nav a')) this.toggleNavigation(false);
      if (event.target.closest('[data-task-search]') && event.button === 0 &&
          !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
        const input = this.el.querySelector('[data-todo-search]');
        if (input) {
          // LiveView handles navigation on the document, even after preventDefault.
          // Stop this local focus action before it reaches that delegated handler.
          event.preventDefault(); event.stopPropagation();
          this.toggleNavigation(false); input.focus(); input.select();
        }
        else { try { sessionStorage.setItem('maraithon:focus-search', 'true'); } catch {} }
      }
      if (event.target.closest('[data-native-sources]')) window.maraithonDesktop?.openSources();
      if (event.target.closest('[data-theme-toggle]')) {
        const modes = ['system', 'light', 'dark'];
        const next = modes[(modes.indexOf(document.documentElement.dataset.theme || 'system') + 1) % modes.length];
        try { localStorage.setItem('maraithon:theme', next); } catch {}
        window.dispatchEvent(new Event('maraithon:theme'));
        this.updateThemeLabel();
      }
    }, options);
    window.addEventListener('keydown', event => {
      if (event.key === 'Tab' && this.mobileNavigation.matches && this.el.classList.contains('navigation-open')) {
        const focusable = [...this.el.querySelector('.workspace-sidebar').querySelectorAll('a, button, input, select')].filter(el => !el.disabled && el.getClientRects().length);
        const first = focusable[0], last = focusable[focusable.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }
      if (event.key === 'Escape' && this.el.classList.contains('navigation-open')) {
        this.toggleNavigation(false);
        this.el.querySelector('[data-sidebar-toggle]')?.focus();
      }
    }, options);
    window.addEventListener('online', () => this.connected(), options);
    window.addEventListener('offline', () => this.disconnected(), options);
    window.addEventListener('maraithon:theme', () => this.updateThemeLabel(), options);
    this.focusPendingSearch = () => {
      const input = this.el.querySelector('[data-todo-search]');
      try {
        if (input && sessionStorage.getItem('maraithon:focus-search')) {
          sessionStorage.removeItem('maraithon:focus-search');
          window.requestAnimationFrame(() => input.focus());
        }
      } catch {}
    };
    window.addEventListener('phx:page-loading-stop', this.focusPendingSearch, options);
    this.syncNavigation();
    this.focusPendingSearch();
    this.updateThemeLabel();
    if (!navigator.onLine) this.disconnected();
  },
  updated() { this.updateThemeLabel(); this.syncNavigation(); this.focusPendingSearch(); },
  updateThemeLabel() {
    const theme = document.documentElement.dataset.theme || 'system';
    const label = this.el.querySelector('[data-theme-label]');
    if (label) label.textContent = theme[0].toUpperCase() + theme.slice(1);
  },
  disconnected() { this.setConnection(false); },
  reconnected() { this.setConnection(true); },
  connected() { this.setConnection(navigator.onLine); },
  setConnection(connected) {
    this.el.querySelector('[data-connection-status]')?.classList.toggle('is-offline', !connected);
    const label = this.el.querySelector('[data-connection-label]');
    if (label) label.textContent = connected ? 'Connected' : 'Reconnecting…';
  },
  destroyed() { this.abort.abort(); }
};

export const TaskCreate = {
  mounted() {
    this.open = () => { this.el.open = true; this.el.querySelector('#new-todo-form input')?.focus(); };
    this.el.addEventListener('maraithon:new-task', this.open);
  },
  destroyed() { this.el.removeEventListener('maraithon:new-task', this.open); }
};
