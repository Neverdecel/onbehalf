import {useEffect, useRef} from 'react';
import {onFrame, type Frame} from '../lib/scroll';

/** Runs fn in the page's rAF loop. The latest fn is used without a new subscription. */
export function useFrame(fn: Frame) {
  const ref = useRef(fn);
  ref.current = fn;
  useEffect(() => onFrame((y, vh) => ref.current(y, vh)), []);
}
