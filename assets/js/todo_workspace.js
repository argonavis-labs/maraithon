import {renderRunnerCards, destroyRunnerCards} from "./runner-cards"
import {renderRunnerConversation, destroyRunnerConversation} from "./runner-conversation"
// Web drafts stay tab-scoped. Electron drafts also survive an app restart.
// Only a server receipt clears a submitted message. Retrying reuses its UUID.
export const TodoWorkspace = {
  mounted() {
    this.connected = true
    this.key = this.el.dataset.storageKey
    try {
      // Keep the hardened web tab isolation. The single desktop window uses an
      // origin-partitioned profile and a user/task key for restart recovery.
      const saved = window.maraithonDesktop ? localStorage.getItem(this.key) || sessionStorage.getItem(this.key) : sessionStorage.getItem(this.key)
      this.saved = JSON.parse(saved) || {}
    } catch (_) { this.saved = {} }
    this.saved.drafts ||= {}
    this.saved.expanded ||= {}
    this.onInput = event => {
      if (event.target.matches('[data-workspace-composer] textarea')) this.saved.composer = event.target.value
      this.persist()
    }
    this.onSubmit = event => {
      const form = event.target
      if (form.matches('[data-workspace-composer]')) {
        event.preventDefault()
        this.ask(form.querySelector('textarea').value)
      }
    }
    this.onClick = event => {
      const button = event.target.closest('button')
      if (!button || button.disabled) return
      if (button.hasAttribute('data-workspace-prompt')) this.ask(button.dataset.workspacePrompt)
      if (button.hasAttribute('data-retry-request') && this.saved.request) this.ask(this.saved.request.body)
      if (button.hasAttribute('data-open-review')) {
        const review = document.getElementById(button.dataset.openReview)
        if (review) { review.dispatchEvent(new Event('runner:expand')); review.scrollIntoView({behavior: 'smooth', block: 'start'}) }
      }
    }
    this.onFocus = () => { if (this.connected) this.pushEvent('workspace_refresh', {}) }
    this.el.addEventListener('input', this.onInput)
    this.el.addEventListener('submit', this.onSubmit)
    this.el.addEventListener('click', this.onClick)
    window.addEventListener('focus', this.onFocus)
    this.restore()
  },
  updated() { this.restore() },
  disconnected() { this.connected = false; this.el.querySelector('[data-workspace-connection]').hidden = false; renderRunnerCards(this); renderRunnerConversation(this) },
  reconnected() {
    this.connected = true
    renderRunnerCards(this)
    renderRunnerConversation(this)
    this.el.querySelector('[data-workspace-connection]').hidden = true
    this.pushEvent('workspace_refresh', {})
  },
  destroyed() {
    destroyRunnerCards(this)
    destroyRunnerConversation(this)
    this.el.removeEventListener('input', this.onInput)
    this.el.removeEventListener('submit', this.onSubmit)
    this.el.removeEventListener('click', this.onClick)
    window.removeEventListener('focus', this.onFocus)
  },
  persist() {
    try { (window.maraithonDesktop ? localStorage : sessionStorage).setItem(this.key, JSON.stringify(this.saved)) } catch (_) {}
  },
  ask(body) {
    body = body.trim()
    if (!body) return
    const status = this.el.querySelector('[data-workspace-status]')
    if (new TextEncoder().encode(body).length > 16384) {
      status.textContent = 'That message is too long. Shorten it and try again.'
      return
    }
    if (this.saved.request && this.saved.request.body !== body) {
      status.textContent = 'The earlier message is awaiting confirmation. Retry it before starting another.'
      return
    }
    this.saved.request ||= {body, id: crypto.randomUUID()}
    this.persist()
    this.restore()
    if (!this.connected) {
      status.textContent = 'Your message is kept here. Retry when the connection returns.'
      return
    }
    this.pushEvent('workspace_send', {body, client_message_id: this.saved.request.id})
  },
  restore() {
    const receipts = JSON.parse(this.el.dataset.receipts || '[]')
    if (this.saved.request && receipts.includes(this.saved.request.id)) {
      if ((this.saved.composer || '').trim() === this.saved.request.body) this.saved.composer = ''
      delete this.saved.request
      this.persist()
    }
    const composer = this.el.querySelector('[data-workspace-composer] textarea')
    if (composer.value !== (this.saved.composer || '')) composer.value = this.saved.composer || ''
    const status = this.el.querySelector('[data-workspace-status]')
    status.textContent = this.saved.request ? `Awaiting confirmation: ${this.saved.request.body.slice(0, 180)}` : ''
    this.el.querySelector('[data-retry-request]').hidden = !this.saved.request
    renderRunnerCards(this)
    renderRunnerConversation(this)
    for (const time of this.el.querySelectorAll('[data-workspace-time]')) {
      try {
        time.textContent = new Intl.DateTimeFormat(undefined, {dateStyle: 'medium', timeStyle: 'short', timeZone: time.dataset.timezone || undefined}).format(new Date(time.dateTime))
      } catch (_) { /* Retain the exact source timestamp when formatting is unavailable. */ }
    }
  }
}

export const TodoTimeline = {
  mounted() {
    this.last = this.el.dataset.lastMessage
    this.first = this.el.querySelector('article')?.id
    this.follow = true
    this.onScroll = () => { this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80 }
    this.el.addEventListener('scroll', this.onScroll, {passive: true})
    // Streamed Markdown and React disclosures can change height independently
    // of a LiveView patch. Follow the bottom only while the reader is there.
    this.observer = new ResizeObserver(() => {
      if (this.follow) this.el.scrollTop = this.el.scrollHeight
    })
    this.observeTurns()
    this.el.scrollTop = this.el.scrollHeight
  },
  observeTurns() {
    this.observer.disconnect()
    for (const child of this.el.children) this.observer.observe(child)
  },
  beforeUpdate() {
    this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
    this.height = this.el.scrollHeight
    this.top = this.el.scrollTop
  },
  updated() {
    const first = this.el.querySelector('article')?.id
    // Preserve the anchor only when history is prepended. A live preview
    // growing below someone reading history must not move their position.
    if (this.follow) this.el.scrollTop = this.el.scrollHeight
    else if (first !== this.first) this.el.scrollTop = this.top + this.el.scrollHeight - this.height
    this.first = first
    this.last = this.el.dataset.lastMessage
    this.observeTurns()
  },
  destroyed() {
    this.observer.disconnect()
    this.el.removeEventListener('scroll', this.onScroll)
  }
}

// The legacy conversation route shares the same presentation and scroll behavior.
// Its existing Phoenix form and AssistantChat request handlers remain authoritative.
export const RunnerConversation = {
  mounted() {
    this.connected = true
    renderRunnerConversation(this)
    TodoTimeline.mounted.call(this)
  },
  observeTurns: TodoTimeline.observeTurns,
  beforeUpdate: TodoTimeline.beforeUpdate,
  updated() {
    renderRunnerConversation(this)
    TodoTimeline.updated.call(this)
  },
  disconnected() { this.connected = false; renderRunnerConversation(this) },
  reconnected() { this.connected = true; renderRunnerConversation(this) },
  destroyed() {
    destroyRunnerConversation(this)
    TodoTimeline.destroyed.call(this)
  }
}
