import { Component, useRef, type ReactNode } from "react";
import { Canvas, useFrame } from "@react-three/fiber";
import type { Mesh } from "three";

class WebGLBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
    state = { failed: false };

    static getDerivedStateFromError() {
        return { failed: true };
    }

    render() {
        if (this.state.failed) return null;
        return this.props.children;
    }
}

const AnimatedCore = () => {
    const sphereRef = useRef<Mesh>(null);

    useFrame(({ clock }) => {
        if (sphereRef.current) {
            const elapsed = clock.getElapsedTime();
            sphereRef.current.rotation.y = elapsed * 0.2;
            sphereRef.current.rotation.x = elapsed * 0.1;
            sphereRef.current.scale.setScalar(2.35 + Math.sin(elapsed * 1.5) * 0.08);
        }
    });

    return (
        <mesh ref={sphereRef}>
            <sphereGeometry args={[1, 96, 96]} />
            <meshStandardMaterial
                color="#a855f7"
                roughness={0.2}
                metalness={0.8}
                emissive="#581c87"
                emissiveIntensity={0.5}
            />
        </mesh>
    );
};

const NeuralCore3D = () => {
    return (
        <WebGLBoundary>
            <div className="w-[300px] h-[300px] md:w-[500px] md:h-[500px]">
                <Canvas camera={{ position: [0, 0, 5] }}>
                    <ambientLight intensity={0.5} />
                    <directionalLight position={[10, 10, 5]} intensity={1} />
                    <pointLight position={[-10, -10, -5]} color="#22d3ee" intensity={1} />
                    <AnimatedCore />
                </Canvas>
            </div>
        </WebGLBoundary>
    );
};

export default NeuralCore3D;
