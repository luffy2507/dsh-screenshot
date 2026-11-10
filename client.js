window.__ModuleLoader__.load({
  id: 'dsh-screenshot',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    const { useState, useRef } = React;

    const NS = 'dsh-screenshot';

    const EN = {
      title: 'Screenshot',
      busy: 'Capturing…',
    };
    const ZH = {
      title: '截图',
      busy: '截图中…',
    };

    const fallbackDict = /^zh/i.test(typeof navigator !== 'undefined' ? navigator.language || '' : '')
      ? ZH
      : EN;
    const fallbackT = (k) => fallbackDict[k] ?? EN[k] ?? k;

    function cameraIcon() {
      return h(
        'svg',
        {
          width: 18,
          height: 18,
          viewBox: '0 0 24 24',
          fill: 'none',
          stroke: 'currentColor',
          strokeWidth: 2,
          strokeLinecap: 'round',
          strokeLinejoin: 'round',
          'aria-hidden': 'true',
        },
        h('path', {
          d: 'M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z',
        }),
        h('circle', { cx: 12, cy: 13, r: 4 })
      );
    }

    function ScreenshotButton(props) {
      const t = typeof props.t === 'function' ? props.t : fallbackT;
      const sessionId = typeof props.sessionId === 'string' ? props.sessionId : '';
      const [busy, setBusy] = useState(false);
      const inflight = useRef(false);

      async function capture() {
        if (inflight.current) return;
        if (!sessionId) return;
        inflight.current = true;
        setBusy(true);
        try {
          await fetch('/screenshot/api/capture', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ sessionId }),
          });
        } catch (_e) {
          // network error is non-fatal; the host route owns the actual work
        } finally {
          inflight.current = false;
          setBusy(false);
        }
      }

      return h(
        'span',
        { style: { display: 'inline-flex', alignItems: 'center', flexShrink: 0 } },
        h(
          'button',
          {
            type: 'button',
            onClick: capture,
            disabled: busy || !sessionId,
            'aria-label': t('title'),
            title: t('title'),
            style: {
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: 28,
              height: 28,
              borderRadius: 6,
              border: 'none',
              background: 'transparent',
              color: 'inherit',
              cursor: busy || !sessionId ? 'default' : 'pointer',
              opacity: busy ? 0.5 : 1,
              padding: 0,
            },
          },
          cameraIcon()
        )
      );
    }

    function apply(ctx) {
      ctx.effect(() => ctx.locale.register(NS, 'en', EN), 'dsh-screenshot: en dictionary');
      ctx.effect(() => ctx.locale.register(NS, 'zh', ZH), 'dsh-screenshot: zh dictionary');

      ctx.effect(() => {
        const dispose = ctx.slots.inject('conversation.input.right', () =>
          ctx.slots.register(
            {
              name: 'conversation.input.right',
              id: 'dsh-screenshot',
              locale: NS,
              inject: (sessionId) => ({ sessionId }),
            },
            ScreenshotButton
          )
        );
        return () => {
          if (typeof dispose === 'function') dispose();
        };
      }, 'dsh-screenshot: composer control');
    }

    return { inject: ['locale', 'slots'], apply };
  },
});
