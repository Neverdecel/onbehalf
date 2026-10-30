import {useEffect} from 'react';
import {Footer, Header} from './components/Chrome';
import {Compare} from './components/Compare';
import {Flow} from './components/Flow';
import {Hero} from './components/Hero';
import {Reel} from './components/Reel';
import {Start} from './components/Start';
import {Statement} from './components/Statement';
import {useReducedMotion} from './hooks/useReducedMotion';
import {useReveal} from './hooks/useReveal';
import {startScroll} from './lib/scroll';

export default function App() {
  const reduced = useReducedMotion();
  useEffect(() => startScroll(reduced), [reduced]);
  useReveal();

  return (
    <>
      <Header />
      <main id="main">
        <Hero reduced={reduced} />
        <Statement reduced={reduced} />
        <Reel reduced={reduced} />
        <Flow reduced={reduced} />
        <Compare />
        <Start />
      </main>
      <Footer />
    </>
  );
}
