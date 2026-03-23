import { useEffect, useRef } from "react";

/**
 * Adds 'visible' class to an element when it enters the viewport.
 * Used with the `.reveal` CSS class in app.css for fade-in-up animations.
 *
 * For staggered children, add inline `style={{ transitionDelay: `${i * 50}ms` }}`
 * to each child element.
 */
export function useScrollReveal<T extends HTMLElement = HTMLDivElement>(
  options?: {
    threshold?: number;
  },
): React.RefObject<T | null> {
  const ref = useRef<T | null>(null);

  useEffect(() => {
    const element = ref.current;
    if (!element) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          element.classList.add("visible");
          observer.unobserve(element);
        }
      },
      { threshold: options?.threshold ?? 0.1 },
    );

    observer.observe(element);

    return () => observer.disconnect();
  }, [options?.threshold]);

  return ref;
}
