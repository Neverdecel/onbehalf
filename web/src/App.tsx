import {useEffect} from 'react';
import {Footer, Header} from './components/Chrome';
import {Flow} from './components/Flow';
import {Hero} from './components/Hero';
import {Reel} from './components/Reel';
import {Story} from './components/Story';
import {Start} from './components/Start';
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
        <Hero />
        <Story reduced={reduced} />
        <Reel reduced={reduced} />
        <Flow reduced={reduced} />
        <Start />
      </main>
      <Footer />
    </>
  );
}
