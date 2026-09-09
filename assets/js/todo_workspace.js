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
      const review = event.target.closest('[data-workspace-review]')
      if (review && review.dataset.editable === 'true') {
        this.saved.drafts[review.dataset.messageId] = this.fields(review.querySelector('form'))
      }
      this.persist()
    }
    this.onToggle = event => {
      if (event.target.matches('[data-workspace-review]')) {
        this.saved.expanded[event.target.id] = event.target.open
        this.persist()
      }
    }
    this.onSubmit = event => {
      const form = event.target
      if (form.matches('[data-workspace-composer]')) {
        event.preventDefault()
        this.ask(form.querySelector('textarea').value)
      } else if (form.matches('[data-workspace-draft]')) {
        event.preventDefault()
        const decision = event.submitter?.dataset.decision
        if (!decision || event.submitter.disabled) return
        this.pushEvent('workspace_decide', {action_id: form.dataset.actionId, decision, draft_edits: form.closest('[data-workspace-review]').dataset.provider === 'browser' ? {} : this.fields(form)})
      }
    }
    this.onClick = async event => {
      const button = event.target.closest('button')
      if (!button || button.disabled) return
      if (button.hasAttribute('data-workspace-prompt')) this.ask(button.dataset.workspacePrompt)
      if (button.hasAttribute('data-retry-request') && this.saved.request) this.ask(this.saved.request.body)
      if (button.hasAttribute('data-open-review')) {
        const review = document.getElementById(button.dataset.openReview)
        if (review) { review.open = true; review.scrollIntoView({behavior: 'smooth', block: 'start'}) }
      }
      const form = button.closest('[data-workspace-draft]')
      if (!form) return
      const fields = this.fields(form)
      const feedback = form.querySelector('[data-draft-feedback]')
      if (button.hasAttribute('data-copy-draft')) {
        try {
          await navigator.clipboard.writeText(fields.body || '')
          feedback.textContent = 'Copied'
        } catch (_) { feedback.textContent = 'Select the message and copy it with your browser.' }
      }
      if (button.hasAttribute('data-open-messages')) {
        const recipient = fields.recipient || ''
        if (!/^(\+?[0-9]{7,15}|[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)$/.test(recipient)) {
          feedback.textContent = 'A verified Messages address is needed. You can copy the draft.'
          return
        }
        // Device handoff only. The app cannot infer delivery from opening Messages.
        const separator = /iPad|iPhone|iPod/.test(navigator.userAgent) ? '&' : '?'
        window.location.href = `sms:${encodeURIComponent(recipient)}${separator}body=${encodeURIComponent(fields.body || '')}`
        feedback.textContent = 'Review and send in Messages. If it does not open on this device, copy the draft.'
      }
      if (button.hasAttribute('data-prepare-email') && form.reportValidity()) {
        this.ask(`Save this reviewed email as a Gmail draft and prepare its approval card. Do not send. Keep the original thread context. From: ${form.dataset.from || 'the source account'}\nTo: ${fields.recipient || ''}\nSubject: ${fields.subject || ''}\nCc: ${fields.cc || ''}\nBcc: ${fields.bcc || ''}\n\n${fields.body || ''}`)
      }
    }
    this.onFocus = () => { if (this.connected) this.pushEvent('workspace_refresh', {}) }
    this.el.addEventListener('input', this.onInput)
    this.el.addEventListener('toggle', this.onToggle, true)
    this.el.addEventListener('submit', this.onSubmit)
    this.el.addEventListener('click', this.onClick)
    window.addEventListener('focus', this.onFocus)
    this.restore()
  },
  updated() { this.restore() },
  disconnected() { this.connected = false; this.el.querySelector('[data-workspace-connection]').hidden = false },
  reconnected() {
    this.connected = true
    this.el.querySelector('[data-workspace-connection]').hidden = true
    this.pushEvent('workspace_refresh', {})
  },
  destroyed() {
    this.el.removeEventListener('input', this.onInput)
    this.el.removeEventListener('toggle', this.onToggle, true)
    this.el.removeEventListener('submit', this.onSubmit)
    this.el.removeEventListener('click', this.onClick)
    window.removeEventListener('focus', this.onFocus)
  },
  persist() {
    try { (window.maraithonDesktop ? localStorage : sessionStorage).setItem(this.key, JSON.stringify(this.saved)) } catch (_) {}
  },
  fields(form) { return Object.fromEntries(new FormData(form).entries()) },
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
    for (const review of this.el.querySelectorAll('[data-workspace-review]')) {
      if (Object.hasOwn(this.saved.expanded, review.id)) review.open = this.saved.expanded[review.id]
      const fields = this.saved.drafts[review.dataset.messageId]
      if (fields && review.dataset.editable === 'true') {
        for (const input of review.querySelectorAll('input[name], textarea[name]')) {
          if (!input.readOnly && Object.hasOwn(fields, input.name) && input.value !== fields[input.name]) input.value = fields[input.name]
        }
      } else if (review.dataset.editable !== 'true') {
        delete this.saved.drafts[review.dataset.messageId]
      }
    }
    for (const time of this.el.querySelectorAll('[data-workspace-time]')) {
      try {
        time.textContent = new Intl.DateTimeFormat(undefined, {dateStyle: 'medium', timeStyle: 'short', timeZone: time.dataset.timezone || undefined}).format(new Date(time.dateTime))
      } catch (_) { /* Retain the exact source timestamp when formatting is unavailable. */ }
    }
  }
}

export const TodoTimeline = {
  mounted() { this.el.scrollTop = this.el.scrollHeight; this.last = this.el.dataset.lastMessage },
  beforeUpdate() { this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80; this.height = this.el.scrollHeight },
  updated() {
    const last = this.el.dataset.lastMessage
    if (last !== this.last && this.follow) this.el.scrollTop = this.el.scrollHeight
    else if (last === this.last && this.el.scrollHeight > this.height && !this.follow) this.el.scrollTop += this.el.scrollHeight - this.height
    this.last = last
  }
}
