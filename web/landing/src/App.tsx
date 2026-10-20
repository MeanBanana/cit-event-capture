import {useEffect} from 'react';
import {AttackLog} from './components/AttackLog';
import {Footer, Header} from './components/Chrome';
import {Contact} from './components/Contact';
import {Download} from './components/Download';
import {Hero} from './components/Hero';
import {Pipeline} from './components/Pipeline';
import {Roles} from './components/Roles';
import {useReducedMotion} from './hooks/useReducedMotion';
import {startScroll} from './lib/scroll';

export default function App() {
  const reduced = useReducedMotion();
  useEffect(() => startScroll(reduced), [reduced]);

  return (
    <>
      <Header />
      <main>
        <Hero />
        <AttackLog />
        <Pipeline />
        <Roles />
        <Download />
        <Contact />
      </main>
      <Footer />
    </>
  );
}
