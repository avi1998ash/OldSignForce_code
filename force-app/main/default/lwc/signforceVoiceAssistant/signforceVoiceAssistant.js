import { LightningElement, track } from 'lwc';
import invokeAgent from '@salesforce/apex/AgentforceProxy.invokeAgent';
import isAgentforceAvailable from '@salesforce/apex/SignForceAccess.isAgentforceAvailable';
import { stripNs } from 'c/nsUtils';

export default class SignforceVoiceAssistant extends LightningElement {
    // Hidden until we confirm Agentforce is available in this org.
    @track agentforceAvailable = false;
    @track messages = [];
    @track inputText = '';
    @track isListening = false;
    @track isThinking = false;
    @track isSpeaking = false;
    @track voiceOutputEnabled = true;
    @track language = 'en-US';

    _recognition;
    _speechSynth;
    _messageIdCounter = 0;
    _autoSendFromVoice = false;
    _agentSessionId = null;

    get hasMessages() { return this.messages.length > 0; }
    get isIdle() { return !this.isListening && !this.isThinking && !this.isSpeaking; }
    get cantSend() { return !this.inputText.trim() || this.isThinking; }
    get micButtonClass() { return this.isListening ? 'sf-voice-mic listening' : 'sf-voice-mic'; }
    get statusLabel() {
        if (this.isListening) return 'Listening';
        if (this.isThinking) return 'Thinking';
        if (this.isSpeaking) return 'Speaking';
        return 'Ready';
    }
    get statusDotClass() {
        if (this.isListening) return 'sf-voice-dot listening';
        if (this.isThinking) return 'sf-voice-dot thinking';
        if (this.isSpeaking) return 'sf-voice-dot speaking';
        return 'sf-voice-dot idle';
    }
    get languageOptions() {
        return [
            { label: 'English (US)', value: 'en-US' },
            { label: 'English (India)', value: 'en-IN' }
        ];
    }

    get suggestions() {
        return [
            { id: 's1', text: "What's the status of NSD agreement?" },
            { id: 's2', text: 'List all agreements' },
            { id: 's3', text: 'Show pending signatures' },
            { id: 's4', text: 'Show available templates' }
        ];
    }

    connectedCallback() {
        isAgentforceAvailable()
            .then((ok) => { this.agentforceAvailable = !!ok; })
            .catch(() => { this.agentforceAvailable = false; });
        this._speechSynth = window.speechSynthesis || null;
        this._initSpeechRecognition();
    }

    disconnectedCallback() {
        if (this._recognition) { try { this._recognition.stop(); } catch (e) { } }
        if (this._speechSynth) this._speechSynth.cancel();
    }

    _initSpeechRecognition() {
        const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
        if (!SpeechRecognition) return;
        this._recognition = new SpeechRecognition();
        this._recognition.continuous = false;
        this._recognition.interimResults = true;
        this._recognition.lang = this.language;
        this._recognition.maxAlternatives = 1;
        this._recognition.onstart = () => { this.isListening = true; this._autoSendFromVoice = false; };
        this._recognition.onresult = (event) => {
            let transcript = '';
            let finalSeen = false;
            for (let i = 0; i < event.results.length; i += 1) {
                transcript += event.results[i][0].transcript;
                finalSeen = finalSeen || event.results[i].isFinal;
            }
            this.inputText = transcript.trim();
            this._autoSendFromVoice = finalSeen;
        };
        this._recognition.onerror = (event) => {
            this.isListening = false;
            if (event.error === 'not-allowed' || event.error === 'permission-denied') {
                this._addMessage('system', 'Please allow microphone access to use voice input.');
            }
        };
        this._recognition.onend = () => {
            this.isListening = false;
            if (this._autoSendFromVoice && this.inputText.trim().length > 1) this.handleSend();
        };
    }

    handleMicToggle() {
        if (!this._recognition) {
            this._addMessage('system', 'Voice input is not supported in this browser. Type your request instead.');
            return;
        }
        if (this.isListening) { this._recognition.stop(); return; }
        if (this._speechSynth) this._speechSynth.cancel();
        this.isSpeaking = false;
        this.inputText = '';
        this._recognition.lang = this.language;
        try { this._recognition.start(); } catch (e) { this.isListening = false; }
    }

    handleInputChange(event) { this.inputText = event.target.value; }
    handleInputKey(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.handleSend();
        }
    }
    handleVoiceToggle(event) {
        this.voiceOutputEnabled = event.target.checked;
        if (!this.voiceOutputEnabled && this._speechSynth) {
            this._speechSynth.cancel();
            this.isSpeaking = false;
        }
    }
    handleLanguageChange(event) {
        this.language = event.target.value || event.detail?.value;
        if (this._recognition) this._recognition.lang = this.language;
    }

    handleSuggestionClick(event) {
        const text = event.currentTarget.dataset.text;
        if (!text) return;
        this.inputText = text;
        this.handleSend();
    }

    async handleSend() {
        const userText = this.inputText.trim();
        if (!userText || this.isThinking) return;
        this._addMessage('user', userText);
        this.inputText = '';
        this.isThinking = true;

        try {
            const reply = stripNs(await invokeAgent({
                userMessage: userText,
                sessionId: this._agentSessionId
            }));
            if (reply && reply.sessionId) {
                this._agentSessionId = reply.sessionId;
            }
            const text = (reply && reply.text)
                ? reply.text
                : 'I could not get a response. Please try rephrasing your question.';
            this._handleAiResponse(text);
        } catch (err) {
            this._handleError(err);
        }
    }

    _handleAiResponse(text) {
        this.isThinking = false;
        this._addMessage('ai', text);
        if (this.voiceOutputEnabled) this._speak(this._stripMarkdownForSpeech(text));
    }

    _handleError(err) {
        this.isThinking = false;
        const msg = err?.body?.message || err?.message || 'Something went wrong.';
        const reply = 'Sorry, I hit an error: ' + msg;
        this._addMessage('ai', reply);
        if (this.voiceOutputEnabled) this._speak(reply);
    }

    // _speak(text) {
    //     if (!this._speechSynth || !text) return;
    //     this._speechSynth.cancel();
    //     const utterance = new SpeechSynthesisUtterance(text);
    //     utterance.rate = 1;
    //     utterance.pitch = 1;
    //     utterance.volume = 1;
    //     utterance.lang = this.language;
    //     utterance.onstart = () => { this.isSpeaking = true; };
    //     utterance.onend = () => { this.isSpeaking = false; };
    //     utterance.onerror = () => { this.isSpeaking = false; };
    //     this._speechSynth.speak(utterance);
    // }

    _speak(text) {
        if (!this._speechSynth || !text) return;
        this._speechSynth.cancel();

        const doSpeak = () => {
            const utterance = new SpeechSynthesisUtterance(text);
            utterance.rate = 1;
            utterance.pitch = 1;
            utterance.volume = 1;
            utterance.lang = this.language;

            const voices = this._speechSynth.getVoices();
            const preferred = voices.find(v => v.name.includes('Aria'))
                || voices.find(v => v.name.includes('Jenny'))
                || voices.find(v => v.name.includes('Google US English'))
                || voices.find(v => v.lang === this.language);
            if (preferred) {
                utterance.voice = preferred;
                console.log('Using voice:', preferred.name);
            }

            utterance.onstart = () => { this.isSpeaking = true; };
            utterance.onend = () => { this.isSpeaking = false; };
            utterance.onerror = () => { this.isSpeaking = false; };
            this._speechSynth.speak(utterance);
        };

        // Voices may load async — wait if needed
        if (this._speechSynth.getVoices().length === 0) {
            this._speechSynth.onvoiceschanged = () => doSpeak();
        } else {
            doSpeak();
        }
    }

    _stripMarkdownForSpeech(text) {
        if (!text) return '';
        return text
            .replace(/\*\*(.+?)\*\*/g, '$1')
            .replace(/\*(.+?)\*/g, '$1')
            .replace(/^[-*•]\s+/gm, '')
            .replace(/^\d+\.\s+/gm, '')
            .replace(/`(.+?)`/g, '$1')
            .replace(/\n+/g, '. ')
            .trim();
    }

    // Parse AI message into structured "parts" for rich rendering.
    // Each part is either a paragraph or a bullet, and contains inline
    // "spans" with bold/normal styling. Template uses if:true to render.
    _parseMessage(text) {
        if (!text) return [];
        const parts = [];
        const lines = text.split('\n');
        let partIdx = 0;

        for (let raw of lines) {
            const line = raw.trim();
            if (!line) continue;

            partIdx += 1;
            const id = 'p-' + partIdx;

            const bulletMatch = line.match(/^[-*•]\s+(.+)$/);
            if (bulletMatch) {
                parts.push({
                    id,
                    isBullet: true,
                    isParagraph: false,
                    spans: this._parseInline(bulletMatch[1], id)
                });
                continue;
            }

            const numMatch = line.match(/^\d+\.\s+(.+)$/);
            if (numMatch) {
                parts.push({
                    id,
                    isBullet: true,
                    isParagraph: false,
                    spans: this._parseInline(numMatch[1], id)
                });
                continue;
            }

            parts.push({
                id,
                isBullet: false,
                isParagraph: true,
                spans: this._parseInline(line, id)
            });
        }

        return parts;
    }

    _parseInline(text, parentId) {
        const spans = [];
        let idx = 0;
        const regex = /\*\*(.+?)\*\*/g;
        let lastEnd = 0;
        let match;
        while ((match = regex.exec(text)) !== null) {
            if (match.index > lastEnd) {
                idx += 1;
                spans.push({
                    id: parentId + '-s' + idx,
                    text: text.substring(lastEnd, match.index),
                    isBold: false,
                    isNormal: true
                });
            }
            idx += 1;
            spans.push({
                id: parentId + '-s' + idx,
                text: match[1],
                isBold: true,
                isNormal: false
            });
            lastEnd = regex.lastIndex;
        }
        if (lastEnd < text.length) {
            idx += 1;
            spans.push({
                id: parentId + '-s' + idx,
                text: text.substring(lastEnd),
                isBold: false,
                isNormal: true
            });
        }
        if (spans.length === 0) {
            spans.push({ id: parentId + '-s1', text, isBold: false, isNormal: true });
        }
        return spans;
    }

    _addMessage(role, text) {
        this._messageIdCounter += 1;
        const now = new Date();
        const isAi = role === 'ai';
        this.messages = [
            ...this.messages,
            {
                id: 'msg-' + this._messageIdCounter,
                role,
                text,
                parts: isAi ? this._parseMessage(text) : null,
                isUser: role === 'user',
                isAi: isAi,
                isSystem: role === 'system',
                timeLabel: now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
                cssClass: role === 'user' ? 'sf-msg-row user' : isAi ? 'sf-msg-row ai' : 'sf-msg-row system'
            }
        ];
        Promise.resolve().then(() => {
            const container = this.template.querySelector('[data-id="messages"]');
            if (container) container.scrollTop = container.scrollHeight;
        });
    }
}