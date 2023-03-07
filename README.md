Observable and signal/slot implementation
=========================================

This library provides event handling mechanisms on two abstraction levels.
Signals/slots are a direct way for events to be propagated to any number of
event receivers. The propagation happens synchronously and has very low
overhead, computationally and memory consumption wise.

Observables on the other hand allow each observer to process events
asynchronously using a separate event queue. The advantage of this approach is
that each observer can process events in order, but independent of the timing
of the source. Additionally, observables can be composed, manipulated and
augmented using a range-like API.

Both, signals and observables, support storing extra data to avoid the need for
creating heap closures when listening for events.

![Build status](https://github.com/s-ludwig/observable/actions/workflows/ci.yml/badge.svg?branch=master)


Signal/slot example
-------------------

`Signal` can be used to create direct call connections between source and
destination. All observer callbacks of a signal will be called synchronously,
whenever the signal gets emitted.

```D
class Slider {
    private {
        double m_value = 0.0;
        Signal!double m_valueChangeSignal;
    }

    @property ref SignalSocket!double valueChangeSignal()
    {
        return m_valueChangeSignal.socket;
    }

    @property void value(double new_value)
    {
        m_value = new_value;
        m_valueChangeSignal.emit(new_value);
    }
}

class Label {
    @property void caption(string caption);
}

class MyDialog {
    private {
        Label m_label;
        Slider m_slider;
        SignalConnection m_valueConnection;
    }

    this()
    {
        m_label = new Label;

        m_slider = new Slider;
        m_slider.valueChangeSignal.connect(m_valueConnection,
            (value) => m_label.caption = value.to!string);
    }
}
```


Observable example
------------------

`Observable` adds an internal event queue to each observer, so that observers
are independent of each other and do not interfere with the observable's
execution.

```D
class Slider {
    private {
        double m_value = 0.0;
        ObservableSource!double m_valueChanges;
    }

    @property ref Observable!double valueChanges()
    {
        return m_valueChanges.observable;
    }

    @property void value(double new_value)
    {
        m_value = new_value;
        m_valueChanges.put(new_value);
    }
}

class Label {
    @property void caption(string caption);
}

class MyDialog {
    private {
        Label m_label;
        Slider m_slider;
        SignalConnection m_valueConnection;
    }

    this()
    {
        m_label = new Label;

        m_slider = new Slider;

        runTask({
            foreach (value; m_slider.valueChanges.subscribe)
                m_label.caption = value.to!string;
        });
    }
}
```


Reactive value example
----------------------

Reactive values simplify the connection of properties by exposing an observable
interface to handle updates. Assigning a reactive value to another will
automatically update the latter whenever the assigned value changes. Reactive
values are also observable, with `subscribe` working just like for `Observable`.

```D
class Slider {
    @property ref Value!double value();
}

class Label {
    @property ref Value!string caption();
}

class MyDialog {
    private {
        Label m_label;
        Slider m_slider;
        SignalConnection m_valueConnection;
    }

    this()
    {
        m_slider = new Slider;

        m_label = new Label;
        m_label.caption = m_slider.value.mapValue!(n => n.to!string);
    }
}
```
